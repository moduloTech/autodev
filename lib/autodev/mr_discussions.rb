# frozen_string_literal: true

# The one definition of "the unresolved discussion threads of a merge request".
#
# There were two, byte-for-byte identical bar the return shape: `MrFixer`'s
# (which fixes the threads) and `PipelineMonitor`'s (which decides whether the MR
# can be delivered). Both answered a GitLab error with `[]`, and on the delivery
# side that reads as "clean MR, nothing left to fix" — so a GitLab blip delivered
# an MR carrying unresolved review threads, with no attention flag, no comment and
# nothing in the journal to betray it (Autodev #62).
#
# Fixing the delivery copy alone would have left the other free to grow the bug
# back at the next copy-paste, and the two had already drifted once (MrFixer's
# gained `build_discussion`, PipelineMonitor's did not). So there is now one, and
# the shape difference stays where it belongs — at the caller: PipelineMonitor
# only counts the threads, MrFixer maps `build_discussion` over the same list to
# get the title and notes it builds a prompt from.
#
# Including classes must have `@client` and `@project_path`.
module MrDiscussions
  private

  # Raises `ApiUnavailableError` when GitLab does not answer — never `[]`. An
  # empty list means one thing only: this MR has no unresolved thread, which is
  # the single fact both callers act on.
  def fetch_unresolved_discussions(mr_iid)
    discussions = GitlabHelpers.answer(:mr_discussions) do
      @client.merge_request_discussions(@project_path, mr_iid, per_page: 100).auto_paginate
    end
    discussions.select { |d| d.notes&.any? && !resolved?(d) }
  end

  # `merge_request_discussions` returns a `Gitlab::PaginatedResponse` whose
  # default page is 20, so `auto_paginate` above is load-bearing: MR 10699 had
  # three unresolved review threads at positions #21-#23 that stayed open forever.
  #
  # A thread with no resolvable note at all is a plain comment (a commit note, a
  # mention), not a review thread — nothing can ever resolve it, so it must not
  # hold delivery.
  def resolved?(discussion)
    resolvable = discussion.notes.select { |n| n.respond_to?(:resolvable) && n.resolvable }
    return true if resolvable.empty?

    resolvable.all? { |n| n.respond_to?(:resolved) && n.resolved }
  end
end
