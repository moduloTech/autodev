# frozen_string_literal: true

class PipelineMonitor
  # Runs the reviewed project's own review skill (Autodev #74).
  #
  # The skill judges and stops — both PowerPanne's and Fast's state in bold that
  # they write nothing without the developer's explicit go-ahead, and
  # `danger-claude` runs `claude -p`, so there is nobody to ask. That STOP is the
  # contract: autodev reads the findings back and posts them itself.
  #
  # **Which copy of the skill judges is not the clone's** (Autodev #89). The
  # clone is of the MR's own branch, and `git clone --depth 1 --branch <b>` is
  # single-branch, so until this fix the review looked for the declared skill on
  # the branch it was judging — a different branch from the one
  # `Autodev::ReviewSkillProbe` reads, and one an MR may modify. The skill is now
  # read over the API from the branch that decides and written into the clone
  # before the injection. `ReviewSkillSource` owns which branch that is, and why —
  # and it is handed `issue.mr_iid`, because the branch that decides the review of
  # a merge request is the one that merge request is going into (Autodev #91,
  # applied here by the review round of this lot).
  module SkillReviewer
    private

    # The boundary of one review: what counts as a review failure, and the clone
    # cleanup. Split from the steps below the way `FixCycle#execute_fix_cycle` is
    # split from `run_fix_cycle`, for the same reason — the boundary is what a
    # reader has to be able to take in at a glance.
    #
    # The `ensure` is the line both sibling clone paths already carry
    # (`FailureHandler#clone_and_fix`, `FixCycle#execute_fix_cycle`). The spec calls
    # the work directory disposable and named `prepare_work_dir` as the idiom; the
    # cleanup half was dropped, so one shallow clone per reviewed ticket accumulated
    # in /tmp until reboot. It has to be `ensure` rather than a trailing statement
    # because three outcomes leave by exception: `ApiUnavailableError` from the
    # publish or from reading the declared skill off the target branch, and
    # `MissingReviewSkillError` from a declared skill that branch does not carry.
    def review_with_skill(issue)
      work_dir = "/tmp/autodev_review_#{@project_path.tr('/', '_')}_#{issue.issue_iid}"
      run_skill_review(work_dir, issue)
    rescue ImplementationError, ReviewContract::InvalidError => e
      log_error "MR !#{issue.mr_iid}: review via skill " \
                "'#{@project_config['review_skill']}' failed: #{e.message}"
      false
    ensure
      FileUtils.rm_rf(work_dir) if work_dir && Dir.exist?(work_dir)
    end

    def run_skill_review(work_dir, issue)
      skill = @project_config['review_skill']
      path = review_contract_path(issue.mr_iid)
      FileUtils.rm_f(path)
      prepare_review_clone(work_dir, issue, skill)
      run_review_skill(work_dir, issue, skill, path)
      publish_from_contract(issue, path)
    end

    # A clone failure is a review failure: unlike a GitLab error while posting,
    # here judgment never started.
    #
    # The four steps are in this order for four separate reasons (Autodev #89).
    # `ReviewSkillSource.locate` runs **first** so a read GitLab could not answer
    # aborts before a clone is paid for. The overlay runs **after the clone**,
    # because it writes into it, and **before the injection**, so
    # `migrate_legacy_skills` still moves a flat `<name>.md` into `<name>/SKILL.md`
    # before anything looks (the Autodev #81 fix round 2 invariant) and so a skill
    # autodev supplies itself is still written after the overlay's drop. And
    # `skill_available?` stays exactly what it was — one `File.exist?` on the
    # clone, after both — which is what keeps
    # `test/skill_layouts_are_one_definition_test.rb` true of the real review step.
    #
    # There is one raise, not two, and that is deliberate: the overlay drops the
    # declared skill from the clone whatever the verdict, so a `missing` verdict
    # arrives here as an empty directory. A branch carrying a stale copy cannot
    # rescue itself.
    #
    # The missing declared skill raises `MissingReviewSkillError` — still a
    # `ConfigError`, so the ruling that this must never fall back to the
    # `mr-review` binary is unchanged, but a class `launch_review` can recognise
    # on its own (Autodev #81). It carries the skill name, the repository path
    # that was looked for and the ref it was looked for on, because all three end
    # up in a GitLab comment an operator reads.
    def prepare_review_clone(work_dir, issue, skill)
      source = ReviewSkillSource.locate(@client, @project_config, skill, mr_iid: issue.mr_iid)
      clone_for_review(work_dir, issue)
      overlay_review_skill(work_dir, skill, source)
      inject_skills(work_dir)
      return if skill_available?(work_dir, skill)

      raise MissingReviewSkillError.new(skill, source[:ref])
    end

    # `clone_and_checkout` raises `GitError` — a sibling of `ImplementationError`
    # under `AutodevError`, not a subclass (Autodev #74 fix round 1) — so it would
    # otherwise escape `review_with_skill`'s rescue instead of counting as a
    # review failure.
    def clone_for_review(work_dir, issue)
      clone_and_checkout(work_dir, issue.branch_name)
    rescue StandardError => e
      raise ImplementationError, "clone failed: #{e.message}"
    end

    # `SkillsInjector.inject` raises nothing of its own, so a `File.write` /
    # `FileUtils.mkdir_p` failure underneath it would escape as a bare `Errno::*`.
    #
    # Split from the clone (it used to be one `clone_and_inject`) because the
    # overlay now sits between them and makes GitLab reads: under a shared
    # `rescue StandardError` those would be reclassed to `ImplementationError`,
    # i.e. read as a review failure, which is precisely what Autodev #62 forbids.
    def inject_skills(work_dir)
      SkillsInjector.inject(work_dir, logger: @logger, project_path: @project_path)
    rescue StandardError => e
      raise ImplementationError, "skill injection failed: #{e.message}"
    end

    # The reads live in `ReviewSkillSource` (shared with the probe). What is here
    # is the sorting: an `ApiUnavailableError` is re-raised untouched so
    # `launch_review` can hand the row back to `checking_pipeline` and the poll
    # abort at its own boundary, while a local file failure — the overlay writes
    # into the clone — is normalised like the injection's, since judgment never
    # started either way.
    def overlay_review_skill(work_dir, skill, source)
      ReviewSkillSource.materialise(@client, @project_path, work_dir, skill, source)
    rescue ApiUnavailableError
      raise
    rescue StandardError => e
      raise ImplementationError, "review skill overlay failed: #{e.message}"
    end

    def skill_available?(work_dir, skill)
      File.exist?(File.join(work_dir, '.claude', 'skills', skill, 'SKILL.md'))
    end

    # `mr_review_timeout` (Reviewer's per-project override, default 3600s), not
    # `dc_timeout` (600s): a full skill run clones, loads the skill and runs its
    # adversarial pass, the same duration profile `mr-review` itself has, not an
    # ordinary implementation call's (Autodev #74 fix round 1).
    def run_review_skill(work_dir, issue, skill, path)
      danger_claude_prompt(work_dir, review_prompt(issue, skill, path),
                           label: "-p (review via #{skill})", timeout: mr_review_timeout)
    end

    def publish_from_contract(issue, path)
      raise ReviewContract::InvalidError, "contract file #{path} was not written" unless File.exist?(path)

      contract = ReviewContract.parse(File.read(path))
      # nil = no diff_refs yet. NOT a success: returning true here would increment
      # review_count, and the next poll would take the post-review branch, find no
      # discussion and deliver the MR without the review ever having been posted —
      # the exact shape Autodev #62 exists to remove.
      publish_review(issue, contract).nil? ? :inconclusive : true
    end

    def review_contract_path(mr_iid)
      "/tmp/autodev_review_#{@project_path.tr('/', '_')}_#{mr_iid}.json"
    end

    def review_prompt(issue, skill, path)
      <<~PROMPT
        Charge le skill `#{skill}`. Revois la merge request !#{issue.mr_iid} contre sa
        branche cible réelle, en appliquant intégralement la discipline du skill, y
        compris sa passe adversariale.

        Tu es en mode non interactif : il n'y a personne à qui demander une validation.
        N'écris rien sur GitLab — ni discussion, ni label, ni commentaire, ni note de
        ticket. Dépose tes constats consolidés dans #{path}, au format :

        {"verdict":"approve|changes_requested","summary":"…",
         "findings":[{"file":"chemin","line":12,"severity":"error|warning|info|nitpick","body":"…"}]}

        Un constat sans `file`/`line` est accepté : il sera rendu dans le commentaire
        de synthèse au lieu d'une discussion inline.
      PROMPT
    end

    def publish_review(issue, contract)
      ReviewPublisher.new(client: @client, project_path: @project_path,
                          logger: @logger, locale: issue.locale.to_sym)
                     .publish(mr_iid: issue.mr_iid, contract: contract)
    end
  end
end
