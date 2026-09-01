# frozen_string_literal: true

# Raised when a GitLab read the caller needs an answer from did not get one
# (Autodev #62).
#
# The point of this class is that it is **not a value**. Every degraded return
# this codebase has had to unpick came from the same shape — `rescue
# Gitlab::Error::ResponseError; []` (or `nil`, or `false`) — and the trouble is
# not the rescue, it is that the substitute is a perfectly plausible answer:
# `[]` unresolved discussions is a clean MR, `[]` failed jobs is a pipeline that
# recovered. The caller has no way to tell an outage from good news, so an API
# blip becomes a verdict, and the verdicts on this path are terminal (a delivery,
# a give-up, a re-arm).
#
# An exception has no such reading. The unit of work — one `PipelineMonitor#check`
# poll, one `MrFixer#fix` round, one `recheck_infra_recovery` — ends at its own
# boundary rescue with the row untouched, and the next poll cycle re-reads. That
# also restores by construction the property Autodev #56's spec claimed and
# Autodev #51 had quietly broken: an API error cannot reach
# `abandon_expired_watch`, because the poll never gets that far.
#
# `what` is the symbolic name of the read (`:pipeline_jobs`, `:mr_discussions`)
# so a log line says which endpoint went dark; Ruby's own `cause` carries the
# `Gitlab::Error::ResponseError` underneath.
#
# `describe` is the one seam a subclass gets (Autodev #91): a member of this
# family whose cause is not an outage — `MissingTargetBranchError`, where GitLab
# answered perfectly well and the answer was "that branch is gone" — must be
# handled by every existing boundary exactly like an outage, and must not tell an
# operator that GitLab went dark.
class ApiUnavailableError < AutodevError
  attr_reader :what

  def initialize(what, error)
    @what = what
    super(describe(what, error))
  end

  private

  def describe(what, error)
    "GitLab did not answer the #{what} read: #{error.message}"
  end
end
