# frozen_string_literal: true

require_relative 'rails_helper'
require_relative 'database_test_helper'

# Autodev #107 — regression: a request whose danger-claude call cannot run
# does not lose a review budget, and is not abandoned.
#
# Measured: bobette's Docker engine was down from 02/09 23:00 UTC to 03/09
# 08:26, every danger-claude call failing in `ensure_volume` before any
# container started, on an API-version mismatch (danger-claude on v1.54, the
# daemon requiring 1.55). 68 failed calls, without interruption.
# powerpanne/core#16030 crossed that window, re-armed the day before by the
# review-arrears sweep under a promise to hand it back to Stephane Meunier. Its
# five `review_failure_count` failures were all counted inside the outage,
# roughly two minutes apart, and at 03:11 it was abandoned under
# `review_failures_exhausted`: a GitLab comment, `Development::StandBy`, the
# ticket handed back. Its merge request was `mergeable, conflicts no` —
# nothing was wrong with it. Docker was.
#
# `dispatch_review_outcome` now answers `:tool_unavailable` and `:clone_failed`
# the way it already answered `:inconclusive` (Autodev #74, #71): neither
# counter moves and the row goes back to the watch. Only `:unusable_output`
# (the contract file is absent or off-schema — a cause specific to this
# request) still spends `review_failure_count`, which is what keeps the bound
# at `REVIEW_FAILURE_THRESHOLD` meaningful rather than emptied out.
class AnOutageIsNotAReviewVerdictTest < ActiveSupport::TestCase # rubocop:disable Metrics/ClassLength
  include DatabaseTestHelper

  # The fixture: the Docker API-version mismatch that took bobette's engine
  # down, as `danger_claude_prompt` would surface it (Autodev #107, measured).
  DOCKER_500 = 'Error response from daemon: client version 1.54 is too old. ' \
               'Minimum supported API version is 1.55 (ensure_volume danger-claude)'

  FakePipeline = Struct.new(:id, :status)
  FakeMr = Struct.new(:state, :head_pipeline)

  # One open MR whose head pipeline is green: the poll takes `handle_green` →
  # `green_first_review`, which is the only caller of `launch_review`. Same
  # shape as `review_inconclusive_does_not_reset_the_watch_clock_test.rb`.
  class StubClient
    def merge_request(_path, _iid) = FakeMr.new('opened', FakePipeline.new(1, 'success'))
  end

  def setup = setup_database

  def monitor(outcome:, sink: fresh_sink)
    mon = PipelineMonitor.allocate
    mon.instance_variable_set(:@client, StubClient.new)
    mon.instance_variable_set(:@project_path, 'g/a')
    mon.instance_variable_set(:@project_config, { 'review_skill' => 'mr-review' })
    mon.instance_variable_set(:@config, {})
    stub_poll_collaborators(mon, sink, outcome)
    stub_abandon_sinks(mon, sink)
    mon
  end

  def fresh_sink = { notify: [], activity: [], activity_warn: [] }

  def stub_poll_collaborators(mon, sink, outcome)
    %i[log log_error].each { |m| mon.define_singleton_method(m) { |*| nil } }
    mon.define_singleton_method(:log_activity) { |_issue, key, **vars| sink[:activity] << [key, vars] }
    mon.define_singleton_method(:log_activity_warn) { |key, **vars| sink[:activity_warn] << [key, vars] }
    mon.define_singleton_method(:claude_available?) { true }
    mon.define_singleton_method(:review_with_skill) { |_| outcome }
  end

  # Every point at which the give-up path leaves the process.
  def stub_abandon_sinks(mon, sink)
    mon.define_singleton_method(:apply_label_attention) { |*| nil }
    mon.define_singleton_method(:apply_label_done) { |*| nil }
    mon.define_singleton_method(:hand_ticket_back) { |*| true }
    mon.define_singleton_method(:notify_localized) { |_iid, key, **vars| sink[:notify] << [key, vars] }
    mon.define_singleton_method(:snapshot) { |*| nil }
  end

  def issue(since: Time.current, review_failure_count: 0)
    Issue.create!(project_path: 'g/a', issue_iid: 1, mr_iid: 7, status: 'checking_pipeline',
                  review_count: 0, review_failure_count: review_failure_count, locale: 'fr',
                  checking_pipeline_since: since, issue_author_id: 3)
  end

  def poll(row, outcome:, sink: fresh_sink)
    monitor(outcome: outcome, sink: sink).send(:check, row)
    sink
  end

  # --- the regression, replayed with the Docker 500 as fixture -------------

  def test_a_docker_outage_during_the_review_spends_no_budget
    row = issue
    poll(row, outcome: :tool_unavailable)

    assert_equal 0, row.reload.review_failure_count
  end

  def test_a_docker_outage_during_the_review_does_not_abandon_the_request
    row = issue
    poll(row, outcome: :tool_unavailable)

    assert_equal 'checking_pipeline', row.reload.status
    assert_not row.reload.needs_attention
  end

  # `skill_reviewer_test.rb#test_a_docker_outage_is_tool_unavailable_not_a_review_failure`
  # is the sibling of this file: it proves `review_with_skill` classifies the
  # DOCKER_500 message as `:tool_unavailable` in the first place. This file
  # proves what happens once that outcome reaches `dispatch_review_outcome`.

  # --- one test per outcome: did the count move, which state is the row in --

  def test_tool_unavailable_spends_nothing_and_stays_in_the_watch
    row = issue
    poll(row, outcome: :tool_unavailable)

    assert_equal [0, 'checking_pipeline'], [row.reload.review_failure_count, row.reload.status]
  end

  def test_clone_failed_spends_nothing_and_stays_in_the_watch
    row = issue
    poll(row, outcome: :clone_failed)

    assert_equal [0, 'checking_pipeline'], [row.reload.review_failure_count, row.reload.status]
  end

  def test_unusable_output_spends_the_budget_and_stays_in_the_watch_below_threshold
    row = issue
    poll(row, outcome: :unusable_output)

    assert_equal [1, 'checking_pipeline'], [row.reload.review_failure_count, row.reload.status]
  end

  # --- five in a row ---------------------------------------------------------

  # #107's rule, and the second neutral review's correction of the first
  # one's remedy. The budget is never spent on an outage, and the row keeps
  # working: what bounds it is the **age** bound, not a per-cause counter.
  #
  # A counter was tried and removed. Keyed on the failure's own message it is
  # inert — git says `Failed to connect … after 75002 ms` and the timing moves
  # every attempt, which is Autodev #99's defect by construction. Keyed on a
  # stable message it fires in ten minutes on a burst of GitLab 502s and asks
  # the client whether their source branch still exists. Neither is a bound on
  # an outage; `pipeline_watch_max_days` is, and its give-up sentence
  # ("watching for N days without ever being able to conclude") is true.
  def test_five_consecutive_tool_unavailable_spend_no_budget_and_keep_watching
    row = issue
    5.times { poll(row, outcome: :tool_unavailable) }
    row.reload

    assert_equal [0, 'checking_pipeline'], [row.review_failure_count, row.status]
    refute row.needs_attention, 'an outage may not give the request up on its own count'
  end

  def test_five_consecutive_clone_failed_spend_no_budget_and_keep_watching
    row = issue
    5.times { poll(row, outcome: :clone_failed) }
    row.reload

    assert_equal [0, 'checking_pipeline'], [row.review_failure_count, row.status]
    refute row.needs_attention
  end

  # And the age bound does end it — the replacement bound has to be real, or
  # the paragraph above is an excuse rather than a design.
  def test_the_age_bound_still_ends_a_row_stuck_in_an_outage
    row = issue(since: 30.days.ago)

    poll(row, outcome: :tool_unavailable)
    row.reload

    assert_equal 'done', row.status
    assert_equal 'pipeline_watch_expired', row.attention_reason
  end

  # And it is not stood down by these outcomes — `resume_watch` restores the
  # clock the poll started with (Autodev #74) instead of restamping it, so the
  # bound keeps its schedule instead of being pushed a poll into the future
  # for ever. Without that, the paragraph above would be the only bound and it
  # would never arrive.
  def test_an_outage_does_not_push_the_age_bound_forward
    row = issue(since: 10.days.ago)
    before = row.checking_pipeline_since

    poll(row, outcome: :tool_unavailable)

    assert_in_delta before.to_f, row.reload.checking_pipeline_since.to_f, 1.0,
                    'the watch clock must not be restamped by an outage poll'
  end

  # The bound that remains must remain: `:unusable_output` is the one cause
  # that is about this merge request meeting this skill, and it still gives
  # the request up after REVIEW_FAILURE_THRESHOLD consecutive occurrences.
  def test_five_consecutive_unusable_output_still_abandons
    row = issue
    5.times { poll(row, outcome: :unusable_output) }

    assert_equal 'done', row.reload.status
    assert row.reload.needs_attention
    assert_equal 'review_failures_exhausted', row.reload.attention_reason
  end

  # --- the watch clock is preserved, exactly like :inconclusive ------------

  def test_resume_after_tool_unavailable_does_not_restamp_the_watch_clock
    row = issue(since: 5.days.ago)
    poll(row, outcome: :tool_unavailable)

    assert_equal 'checking_pipeline', row.reload.status
    assert_operator row.reload.checking_pipeline_since, :<, 4.days.ago
  end

  def test_resume_after_clone_failed_does_not_restamp_the_watch_clock
    row = issue(since: 5.days.ago)
    poll(row, outcome: :clone_failed)

    assert_equal 'checking_pipeline', row.reload.status
    assert_operator row.reload.checking_pipeline_since, :<, 4.days.ago
  end

  # --- the bound that replaces the spent budget: it is real, not assumed ----
  #
  # If `resume_after_non_spending_outcome` raised `poll_inconclusive!` instead
  # of leaving the flag alone, the bound below would stand down for every
  # poll and this row would never be abandoned — exactly the unbounded,
  # unsignalled loop Autodev #74 avoided for `:inconclusive`.

  def test_a_watch_stuck_on_tool_unavailable_still_expires_at_the_age_bound
    row = issue(since: 40.days.ago)
    sink = poll(row, outcome: :tool_unavailable)

    assert_equal ['done', true, 'pipeline_watch_expired'],
                 [row.reload.status, row.reload.needs_attention, row.reload.attention_reason]
    assert_equal :pipeline_watch_expired, sink[:notify].last.first
  end

  def test_a_watch_stuck_on_clone_failed_still_expires_at_the_age_bound
    row = issue(since: 40.days.ago)
    sink = poll(row, outcome: :clone_failed)

    assert_equal ['done', true, 'pipeline_watch_expired'],
                 [row.reload.status, row.reload.needs_attention, row.reload.attention_reason]
    assert_equal :pipeline_watch_expired, sink[:notify].last.first
  end

  # --- no GitLab comment on a non-spending outcome --------------------------
  #
  # `log_activity` is what upserts the single GitLab activity note (and the
  # DB row that mirrors it); `log_activity_warn` is DB-only, the same
  # precedent `:inconclusive` already set (Autodev #53's growth bound). The
  # ordinary poll still writes its own `log_activity` lines before the review
  # outcome is even known (`:pipeline_checking`, `:pipeline_green`,
  # `:reviewing`) — what must not appear among them is a line claiming a
  # review failure that never happened. The operator still gets a
  # distinguishable line in the issue timeline — just not on the ticket.

  def test_no_review_failure_line_on_tool_unavailable
    row = issue
    sink = poll(row, outcome: :tool_unavailable)

    refute_includes sink[:activity].map(&:first), :review_failed
  end

  def test_no_review_failure_line_on_clone_failed
    row = issue
    sink = poll(row, outcome: :clone_failed)

    refute_includes sink[:activity].map(&:first), :review_failed
  end

  # --- and nothing is written to the journal per poll (alpha-53 review, G3b) --
  #
  # This is the half that mattered. `log_activity_warn` is DB-only, which is
  # why writing one on every poll of an outage looked free. It is not:
  # `Issue.without_activity_since` is the clause common to all three of
  # `DormantAudit`'s arms, so a row writing an activity line every cycle
  # leaves the safety net Autodev #103 had just widened — for as long as the
  # outage lasts, which is exactly when it is needed. The countdown is logged
  # instead; the give-up, which happens once, is what reaches the journal.

  def test_an_outage_writes_no_activity_row_per_poll
    row = issue
    sink = poll(row, outcome: :tool_unavailable)

    assert_empty sink[:activity_warn],
                 'an activity row per poll takes the request out of DormantAudit for the whole outage'
  end

  # Deliberately asserted on the sink above and **not** on
  # `Issue.without_activity_since`: this harness routes `log_activity_warn`
  # into a sink rather than into `activity_events`, so a database-level
  # assertion here would pass whether the fix is present or not — which is the
  # class of test the alpha-53 review objected to. The sink assertion fails
  # without the fix, verified by re-introducing it.
end
