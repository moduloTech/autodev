# frozen_string_literal: true

# A rebase onto the target branch that could not be completed (Autodev #138).
#
# `RepoRebaser` used to answer this with the symbol `:failed` and leave the branch
# where it was, "stale-but-clean ground", and all three callers discarded the
# symbol: the implementation, the discussion fixes and the pipeline fixes then ran
# on a base the target had left behind, and the review that followed judged that
# base. On powerpanne 12935 (09/10/2026) the implementation was pushed on a base
# 865 commits behind `master`, and the review asserted that a class the reviewer
# had asked for did not exist.
#
# An exception because a symbol is what every caller ignored: a caller cannot ignore
# what it never rescues. Each boundary names this class above its generic clause
# and stops the line (`RebaseConflictStop`).
#
# Deliberately NOT an `ApiUnavailableError`. That family means "this cycle
# concluded nothing, come back next cycle", and the next cycle would clone, hit the
# same conflict on the same commits and pay another danger-claude resolution.
#
# `files` are the paths git still listed as unmerged when it refused to continue —
# read before `git rebase --abort`, which erases them — or, failing that, the ones
# it stopped on in the first place. It may be empty: git can refuse for a reason
# that leaves nothing unmerged, and that is still a rebase that did not happen.
class RebaseConflictError < AutodevError
  attr_reader :branch, :base, :files

  def initialize(branch:, base:, files:)
    @branch = branch.to_s
    @base = base.to_s
    @files = Array(files).map(&:to_s)
    listed = @files.empty? ? 'no file listed as unmerged' : @files.join(', ')
    super("rebase of #{@branch} onto origin/#{@base} could not be completed (#{listed})")
  end
end
