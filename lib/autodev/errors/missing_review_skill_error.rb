# frozen_string_literal: true

# A project declares a `review_skill` the clone has no `SKILL.md` for
# (Autodev #74, named as its own class by Autodev #81).
#
# It stays a `ConfigError`: refusing to fall back to the `mr-review` binary is
# still the right answer — that would run a different process from the one the
# project declared, silently — and every reader that only knows about
# `ConfigError` keeps behaving as it did.
#
# What the subclass buys is a *handle*. Autodev #74 left this escaping
# `launch_review`, so the row stayed in `reviewing`, which no dispatch pass
# selects, and the only thing that eventually reached a human was the dormant
# audit five hours later under `dormant_exhausted` — "this line stopped moving",
# never "the declared review skill is not in the repository". `PipelineMonitor`
# can now recognise this one cause precisely and give the request up under a
# reason that names it, without widening the rescue to `ConfigError` at large,
# whose other members it would have no idea what to do with.
#
# `skill` is the declared name, `relative_path` the repository path the review
# step looked for and `ref` the branch it looked on — the three things an
# operator needs in order to fix it, so they travel as data rather than as prose
# to be re-parsed out of the message.
#
# `ref` arrived with Autodev #89, and it is the difference between a true message
# and a misleading one. Until then this named the *work directory* of a clone of
# the MR's own branch, because that is where the review looked; the branch that
# decides is the project's `target_branch` (else the repository's default
# branch), which is a different branch and, measured on production, usually the
# one that actually carries the skill. Saying "missing" without saying "from
# where" is how request powerpanne 15842 was given up on 28/08 under a reason
# whose immediate cause was correct and whose reading was false.
class MissingReviewSkillError < ConfigError
  attr_reader :skill, :relative_path, :ref

  # The canonical layout, which is what an operator should be told to add — the
  # flat one `SkillsInjector` still migrates is accepted, not recommended. Read
  # from the one list so this cannot name a path the review step does not use.
  def self.skill_path(skill) = ::SkillsInjector.skill_paths(skill).first

  def initialize(skill, ref)
    @skill = skill.to_s
    @ref = ref.to_s
    @relative_path = self.class.skill_path(skill)
    super("project declares review_skill '#{@skill}' but #{@relative_path} is missing from " \
          "'#{@ref}' — refusing to fall back to the mr-review binary, which would run a different process")
  end
end
