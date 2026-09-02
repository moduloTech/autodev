# frozen_string_literal: true

# A transition decided on a state the database no longer holds (Autodev #97).
#
# Raised by `Issue#persist_status_change!` when the row's status has moved since
# this object was loaded — a human closed the request from the dashboard, forced
# a transition, reset it, or a startup recovery repositioned it — while a long
# danger-claude call was still running. `save!` would write every dirty attribute
# over the top, which is a lost update: on 01/09/2026 it resurrected a request
# eight minutes after it had been closed, and the close had not held.
#
# It is deliberately NOT an `ApiUnavailableError`: nothing is unavailable and
# nothing should be retried. The row is exactly where a human wanted it, and the
# only correct thing left to do is stop and say so. Every boundary that would
# otherwise answer an unexpected error by writing — the row's `error_message`, a
# GitLab comment — names this class above its generic clause, because those
# writes are the second thing autodev would say about a ticket it was told to
# leave alone.
class StaleTransitionError < AutodevError; end
