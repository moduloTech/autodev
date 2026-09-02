# frozen_string_literal: true

# What a unit of work does when the row it was deciding about has moved
# (Autodev #97). One line of behaviour, and a paragraph of why, shared by the
# three boundaries that can reach it: the poll, the fix round and the initial
# implementation.
module StaleTransitionBound
  private

  # A human moved the row while this work was running (Autodev #97).
  #
  # Nothing more is written — not the row, not a GitLab comment — because the row
  # is exactly where somebody put it, and every write from here is autodev
  # arguing with them. That is the whole remedy: the ticket asked for the work to
  # stop, and stopping is what it now does.
  #
  # What happens to the work already done is decided here rather than left to
  # fall out: whatever reached the branch stays on the branch. It is on GitLab,
  # nothing local can take it back, and the next poll would read it as it is if
  # the request is ever re-armed. What is dropped is the *claim* — the state
  # change and the comment announcing it — which is the only part that was
  # decided against a state that no longer exists.
  def stop_on_stale_transition(error)
    log_error "Stopping: #{error.message}"
  end
end
