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
# The project config's `target_branch`, else the repository's default branch.
# **Never the merge request's own `target_branch`**: no reader of that field
# exists anywhere in the tree, `IssueProcessor::MrManager#create_mr` and
# `RepoRebaser` both read the config, and the probe runs *per project, once per
# cycle*, so it structurally cannot read a per-MR value. Measured: 22 of the 23
# MRs target `staging` while `projects.target_branch` has been `master` since
# 25/08, and the skill is present on both with the same sha256 — so for that
# population the two answers coincide, which is exactly the situation in which a
# second definition drifts unnoticed.
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
# somebody, so the healthy case pays nothing.
module ReviewSkillSource
  PRESENT = 'present'
  MISSING = 'missing'
  UNKNOWN = 'unknown'

  # A skill *directory* name. Anything else cannot be a path segment under
  # `.claude/skills/`, so it is answered without asking GitLab — which is also
  # where Autodev #81's option 3 (a shape check on the form) ended up, in the one
  # place where it produces a verdict rather than a second opinion.
  NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

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
  # (Autodev #91): a fleet scan holds no merge request, so it is that module's
  # question 1 — but a hand-written copy of the answer could not say so, and this
  # file used to carry one.
  def ref_for(client, project_config)
    ::TargetBranch.for_fleet_scan(client, project_config, project_config['path'])
  end

  # `{ status:, ref:, layout: }`. `layout` is the repository path the skill was
  # found at, `nil` when it was not found there *or* when autodev supplies it
  # itself — the two cases `status` separates.
  #
  # Raises `ApiUnavailableError` when a read did not answer, or when the ref it
  # would have accused the configuration over could not be confirmed. It never
  # returns `unknown`: this shape has no value for "I do not know", by design.
  def locate(client, project_config, skill)
    return { status: PRESENT, ref: nil, layout: nil } if self_injected?(skill)

    ref = ref_for(client, project_config)
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

    blobs_under(client, project_path, File.dirname(layout), source[:ref]).each do |blob|
      write_file(client, project_path, work_dir, blob, source[:ref])
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
  def confirm_ref!(client, project_path, ref)
    ::GitlabHelpers.answer(:review_skill_ref) { client.commit(project_path, ref) }
  end

  def blobs_under(client, project_path, dir, ref)
    entries = ::GitlabHelpers.answer(:review_skill_tree) do
      client.tree(project_path, path: dir, ref: ref, recursive: true, per_page: 100)
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
