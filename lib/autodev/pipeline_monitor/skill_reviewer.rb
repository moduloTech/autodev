# frozen_string_literal: true

class PipelineMonitor
  # Runs the reviewed project's own review skill (Autodev #74).
  #
  # The skill judges and stops — both PowerPanne's and Fast's state in bold that
  # they write nothing without the developer's explicit go-ahead, and
  # `danger-claude` runs `claude -p`, so there is nobody to ask. That STOP is the
  # contract: autodev reads the findings back and posts them itself.
  module SkillReviewer
    private

    def review_with_skill(issue)
      skill = @project_config['review_skill']
      work_dir = "/tmp/autodev_review_#{@project_path.tr('/', '_')}_#{issue.issue_iid}"
      path = review_contract_path(issue.mr_iid)
      FileUtils.rm_f(path)

      prepare_review_clone(work_dir, issue, skill)
      run_review_skill(work_dir, issue, skill, path)
      publish_from_contract(issue, path)
    rescue ImplementationError, ReviewContract::InvalidError => e
      log_error "MR !#{issue.mr_iid}: review via skill '#{skill}' failed: #{e.message}"
      false
    end

    # A clone failure is a review failure: unlike a GitLab error while posting,
    # here judgment never started.
    def prepare_review_clone(work_dir, issue, skill)
      clone_and_checkout(work_dir, issue.branch_name)
      SkillsInjector.inject(work_dir, logger: @logger, project_path: @project_path)
      return if skill_available?(work_dir, skill)

      raise ConfigError,
            "project declares review_skill '#{skill}' but #{work_dir}/.claude/skills/#{skill}/SKILL.md " \
            'is missing — refusing to fall back to the mr-review binary, which would run a different process'
    end

    def skill_available?(work_dir, skill)
      File.exist?(File.join(work_dir, '.claude', 'skills', skill, 'SKILL.md'))
    end

    def run_review_skill(work_dir, issue, skill, path)
      danger_claude_prompt(work_dir, review_prompt(issue, skill, path), label: "-p (review via #{skill})")
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
