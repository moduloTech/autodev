# frozen_string_literal: true

# The one definition of "which revision decides a project's review skill, what
# question is asked about it, and how it is put in front of the review"
# (Autodev #89).
#
# ## Why it exists
#
# The review step and the start-up probe read two different branches, and nothing
# said so. `SkillReviewer` cloned `issue.branch_name` — the MR's *source* branch,
# and `git clone --depth 1 --branch <b>` is single-branch, so nothing else was
# even fetchable — and looked for the declared skill in that clone.
# `Autodev::ReviewSkillProbe` (Autodev #81) asked GitLab about the project's
# `target_branch`. Measured on production on 31/08/2026: 13 of the 23 branches of
# the ticket-88 population carry neither `.claude/skills/mr-review/SKILL.md` nor
# the flat layout, while the probe answered "2 declared, 2 present" — and it was
# right. Request powerpanne 15842 was given up under `review_skill_missing` on
# 28/08 for exactly that, a reason naming the correct immediate cause and
# inviting a false conclusion: the project does declare a skill, and the skill
# does exist.
#
# Moving the review's question onto the target branch without moving *both* into
# one place would only have displaced the gap. This repository has removed the
# same shape twice already — `MrState` (Autodev #72) and
# `SkillsInjector.skill_paths` (Autodev #81) — each time after a duplicated
# definition had diverged.
#
# ## Which ref
#
# A **target** branch — never the branch under review — and which target is
# `TargetBranch`'s question, asked and not restated here (Autodev #91). The review
# holds a merge request, so it is question 2: the branch that merge request is
# going into. The probe sweeps the fleet project by project with no merge request
# in hand, so it is question 1: the config's `target_branch`, else the
# repository's default branch.
#
# Autodev #89 originally routed both to question 1, justified by "a fleet scan
# holds no merge request" — true of the probe, false of the review, which is
# handed an `Issue`. The review round of the lot corrected it: the ruling on
# "which target does an existing merge request have" belongs to Autodev #91, and
# a merge request is judged under the conventions of the branch it is going into.
# The two answers coincide for the whole fleet as measured (01/09/2026: 30 open
# merge requests, 30 on `master`, which is the configuration), which is exactly
# the situation in which a divergence goes unnoticed — hence
# `test/the_review_reads_the_merge_requests_target_test.rb`.
#
# ## The target wins, always
#
# A merge request may modify the review skill, and it is still the target's copy
# that judges it. This is the Autodev #79 ruling one layer up ("a resolution is a
# claim, and it may not be made by the agent that produced the correction"):
# letting a branch supply the rules that judge it is the same self-referential
# loop. An exception for "if the branch carries the skill, use the branch's" would
# reinstate the defect for the 13 branches that carry a stale `review` copy.
#
# That argument excludes the **source** branch, and only it. It does not reach the
# merge request's target, because a merge request cannot modify its own target:
# GitLab records it, and retargeting is a human action on GitLab.
#
# ## A failed read is never a verdict
#
# Every read goes through `GitlabHelpers.answer`, so an outage raises
# `ApiUnavailableError` and never `missing`. `locate` is the raising shape, for
# the review step — `Reviewer#launch_review` already hands the row back to
# `checking_pipeline` and re-raises, so the correct behaviour costs no new
# recovery branch. `verdict` is the same answer as data, for the probe, whose
# third value `unknown` is what an unreadable answer records.
#
# The trap that makes the ref confirmation necessary, and it was already live in
# Autodev #81: GitLab answers `404 Commit Not Found` for a ref that does not
# exist and `404 File Not Found` for a file that does not, and **both arrive as
# `Gitlab::Error::NotFound`**. Read naively, a `target_branch` that has been
# deleted or renamed reads as "the skill is missing" and the blame lands on the
# configuration. So before `missing` may be concluded the ref itself is
# confirmed — one extra request, and only on the path that is about to accuse
# somebody, so the healthy case pays nothing. What that confirmation *reports* is
# `MissingTargetBranchError` since the review round: it used to leave as "GitLab
# did not answer", which is the one thing that had not happened.
module ReviewSkillSource
  PRESENT = 'present'
  MISSING = 'missing'
  UNKNOWN = 'unknown'

  # A skill *directory* name. Anything else cannot be a path segment under
  # `.claude/skills/`, so it is answered without asking GitLab — which is also
  # where Autodev #81's option 3 (a shape check on the form) ended up, in the one
  # place where it produces a verdict rather than a second opinion.
  NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

  # What a review skill may weigh. Both are ceilings on a *pathological* value —
  # powerpanne's `mr-review` is 3 blobs and `prepare-mr` 2 — not budgets to be
  # spent: a `review_skill` naming a directory that is not a skill is the case
  # they exist for, and the alternative is one HTTP request per file of an
  # arbitrarily large tree. See `write_subtree` for why exceeding them is a review
  # failure rather than an outage or a missing file.
  MAX_SKILL_BLOBS = 200
  MAX_SKILL_BYTES = 5_000_000

  module_function

  # `.presence`, the reading `Reviewer#launch_review` already gives it: `''` is
  # truthy in Ruby and `Project#to_project_config` emits every column of the row,
  # so a blank has to read as "no skill declared", or a project on the `mr-review`
  # binary path is reported at fault.
  def declared(project_config) = project_config['review_skill'].to_s.strip.presence

  # Every layout under which a declared skill is available to a danger-claude
  # run, canonical first (Autodev #81, fix round 2). One list, named by the module
  # that owns both shapes.
  def layouts(skill) = ::SkillsInjector.skill_paths(skill)

  # `SkillsInjector` writes these into every clone whatever the repository holds,
  # so the repository is not asked about them and no ref decides. Without the
  # derogation a project declaring `code-conventions` would get a green probe and
  # a failing review — today's defect exactly inverted.
  def self_injected?(skill) = ::SkillsInjector::SKILL_NAMES.include?(skill.to_s)

  # The branch that decides. Asked of `TargetBranch`, never restated here
  # (Autodev #91), and asked as **the same question the rebase asks**: `mr_iid`
  # nil is question 1 (the configuration, else the repository default), `mr_iid`
  # set is question 2 (the target that merge request carries).
  #
  # The review round of this lot is what put the second half back. This routed
  # unconditionally to question 1 with the justification "a fleet scan holds no
  # merge request", which is true of the probe and false of the other caller:
  # `SkillReviewer#prepare_review_clone` is handed an `Issue` and holds
  # `issue.mr_iid`. Autodev #89's own argument does not cover the difference
  # either — "a merge request may not supply the rules that judge it" excludes the
  # **source** branch, which nothing here reads, and says nothing about preferring
  # the configuration's target to the merge request's, since a merge request
  # cannot modify its own target. So Autodev #91's rule carries: a merge request is
  # judged under the conventions of the branch it is going into.
  #
  # The probe passes nothing and keeps question 1, correctly: it sweeps every
  # project once per cycle with no merge request in hand.
  def ref_for(client, project_config, mr_iid = nil)
    path = project_config['path']
    ::TargetBranch.resolve(mr_iid, client: client, project_path: path, project_config: project_config) do
      ::TargetBranch.repository_default(client, path)
    end
  end

  # `{ status:, ref:, layout: }`. `layout` is the repository path the skill was
  # found at, `nil` when it was not found there *or* when autodev supplies it
  # itself — the two cases `status` separates.
  #
  # Raises `ApiUnavailableError` when a read did not answer, or when the ref it
  # would have accused the configuration over could not be confirmed. It never
  # returns `unknown`: this shape has no value for "I do not know", by design.
  def locate(client, project_config, skill, mr_iid: nil)
    return { status: PRESENT, ref: nil, layout: nil } if self_injected?(skill)

    ref = ref_for(client, project_config, mr_iid)
    return { status: MISSING, ref: ref, layout: nil } unless skill.to_s.match?(NAME)

    layout = layout_on_ref(client, project_config['path'], skill, ref)
    { status: layout ? PRESENT : MISSING, ref: ref, layout: layout }
  end

  # The same answer as data rather than as an exception, for `ReviewSkillProbe`:
  # `unknown` is a real verdict and is not `missing` (Autodev #62 applied to a
  # read whose answer accuses the operator of a typo). The ref is still reported
  # when it was known without a request, so the recorded fault can name it.
  def verdict(client, project_config, skill)
    locate(client, project_config, skill)
  rescue StandardError
    { status: UNKNOWN, ref: ::TargetBranch.declared(project_config), layout: nil }
  end

  # Canonical first, stopping on the first hit, so a fleet on the current layout
  # costs one request per declaring project; only a repository that does not carry
  # it pays for the second question. `NotFound` on *every* layout is the one thing
  # that may read as absent, and even then only once the ref is confirmed.
  def layout_on_ref(client, project_path, skill, ref)
    found = layouts(skill).find { |path| file_on_ref?(client, project_path, path, ref) }
    return found if found

    confirm_ref!(client, project_path, ref)
    nil
  end

  # Materialises the declared skill into `work_dir`, from `ref` rather than from
  # whatever the clone happens to hold.
  #
  # The declared skill's layouts are removed **first and unconditionally**: the
  # branch under review may carry a stale copy, and leaving it there would let it
  # win — either directly, or through a `references/` file the target branch no
  # longer has sitting beside the target's own `SKILL.md`. The whole skill
  # directory goes, not just `SKILL.md`, because the skill is multi-file
  # (powerpanne's `mr-review` carries two `references/*.md`, prepare-mr one).
  #
  # And it is a subtree read rather than a single `get_file` for the same reason:
  # a lone `SKILL.md` would reference files that are not there. `git show
  # origin/<ref>:…` is not an option — the review clone is `--single-branch`, so
  # `origin/<ref>` does not exist in it.
  #
  # Called *before* `SkillsInjector.inject`, so the flat layout keeps being
  # migrated to the canonical one by `migrate_legacy_skills` before
  # `skill_available?` looks (the Autodev #81 fix round 2 invariant), and so a
  # skill autodev injects itself is still written after the drop.
  def materialise(client, project_path, work_dir, skill, source)
    drop(work_dir, skill)
    layout = source[:layout]
    return if layout.nil?

    return write_file(client, project_path, work_dir, layout, source[:ref]) unless directory_layout?(layout, skill)

    write_subtree(client, project_path, work_dir, skill, source)
  end

  # One `file_contents` per blob, and both ceilings applied around them (review
  # round, constat 4 corollary). A `review_skill` that names a directory which is
  # not a skill would otherwise be downloaded whole, file by file, with no bound on
  # the request count or on the bytes.
  #
  # `ImplementationError` because that is what this path already means by "the
  # review could not be run, and GitLab is not at fault": `overlay_review_skill`
  # normalises its local failures to it, `launch_review` counts it as one review
  # failure, and `REVIEW_FAILURE_THRESHOLD` bounds those. Deliberately *not*
  # `MissingReviewSkillError`, which is terminal and would assert that a file is
  # absent when the problem is that far too many are present; and deliberately not
  # a truncation, which is the silent shape this whole constat is about.
  def write_subtree(client, project_path, work_dir, skill, source)
    blobs = blobs_under(client, project_path, File.dirname(source[:layout]), source[:ref])
    if blobs.size > MAX_SKILL_BLOBS
      raise ImplementationError, "review skill '#{skill}' has #{blobs.size} files on '#{source[:ref]}', " \
                                 "more than the #{MAX_SKILL_BLOBS} a skill may carry"
    end

    blobs.reduce(0) do |bytes, blob|
      written = bytes + write_file(client, project_path, work_dir, blob, source[:ref])
      next written unless written > MAX_SKILL_BYTES

      raise ImplementationError, "review skill '#{skill}' exceeds #{MAX_SKILL_BYTES} bytes on '#{source[:ref]}'"
    end
  end

  # -- the reads ---------------------------------------------------------------

  def file_on_ref?(client, project_path, file_path, ref)
    ::GitlabHelpers.answer(:review_skill_file) do
      client.get_file(project_path, file_path, ref)
      true
    rescue ::Gitlab::Error::NotFound
      false
    end
  end

  # Costs nothing in the healthy case: the call is only made when `missing` is
  # about to be concluded.
  #
  # And when it concludes, it says what happened. Until the review round this let
  # `GitlabHelpers.answer` turn the `404 Commit Not Found` into "GitLab did not
  # answer the review_skill_ref read: …" — while GitLab had answered, precisely and
  # correctly, that the branch is not there. Autodev #91 had already built the
  # class for saying that without blaming an outage; this is the neighbouring case
  # it was built for, and it is `confirmed?` because the repository itself is the
  # authority on which refs it carries. Every other failure of this read is still
  # an outage and still refuses to conclude anything.
  def confirm_ref!(client, project_path, ref)
    ::GitlabHelpers.answer(:review_skill_ref) { client.commit(project_path, ref) }
  rescue ::ApiUnavailableError => e
    raise unless e.cause.is_a?(::Gitlab::Error::NotFound)

    raise MissingTargetBranchError.new(ref, 'the branch that decides the review skill is not on the repository',
                                       confirmed: true)
  end

  # `per_page: 100` **and** `.auto_paginate`, the pair this repository uses at
  # every other list read (`gitlab_helpers.rb`, four times). GitLab caps `per_page`
  # at 100 and `Gitlab::PaginatedResponse#each` walks the current page only, so
  # without the second half this answered the first hundred entries and called it
  # the subtree — and `materialise` drops the clone's copy before writing, so a
  # `SKILL.md` that missed page 1 produced `MissingReviewSkillError`: a terminal
  # give-up asserting that a file is absent which `locate` had just found on that
  # very ref (review round, constat 4).
  def blobs_under(client, project_path, dir, ref)
    entries = ::GitlabHelpers.answer(:review_skill_tree) do
      client.tree(project_path, path: dir, ref: ref, recursive: true, per_page: 100).auto_paginate
    end
    entries.select { |entry| ::GitlabHelpers.field(entry, :type) == 'blob' }
           .map { |entry| ::GitlabHelpers.field(entry, :path) }
  end

  # The gitlab gem's `file_contents` hits the `/raw` endpoint and hands back the
  # bytes (`repository_files.rb`), so there is no base64 to decode.
  def write_file(client, project_path, work_dir, repo_path, ref)
    body = ::GitlabHelpers.answer(:review_skill_file_contents) do
      client.file_contents(project_path, repo_path, ref)
    end
    target = File.join(work_dir, repo_path)
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, body)
  end

  # -- the clone side ----------------------------------------------------------

  def drop(work_dir, skill)
    paths = layouts(skill).map { |layout| File.join(work_dir, layout) }
    FileUtils.rm_rf([*paths, File.join(work_dir, ::SkillsInjector::SKILLS_DIR, skill.to_s)])
  end

  # True for a layout whose file lives *inside* the skill's own directory, which
  # is the shape a whole subtree has to be read for. Derived from the path rather
  # than from the list's ordering, so a third layout does not silently pick the
  # wrong branch here.
  def directory_layout?(layout, skill)
    File.dirname(layout) == File.join(::SkillsInjector::SKILLS_DIR, skill.to_s)
  end
end
