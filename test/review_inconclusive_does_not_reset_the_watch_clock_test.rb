# frozen_string_literal: true

require_relative 'rails_helper'
require_relative 'database_test_helper'

# Autodev #74, fix round 2 — the third review outcome must not stand the age
# bound down by accident.
#
# `review_done!` transitions into `checking_pipeline`, and
# `Issue#stamp_pipeline_watch!` writes `checking_pipeline_since = Time.current` on
# *every* transition into that state. That is right for a row that is moving (a
# fix cycle ping-ponging through `fixing_pipeline` restarts the clock, and should),
# and wrong for one that left the state and came straight back having done
# nothing: an `:inconclusive` review publishes nothing and touches neither
# counter, so each poll restarted the clock and `abandon_expired_watch` could
# never fire. The bound exists because one production ticket polled 29 773 times
# (Autodev #53); every poll of this shape pays a fresh clone plus a full skill run
# under `mr_review_timeout`.
#
# Deliberately *not* `poll_inconclusive!`: that flag stands the bound down for the
# cycle, and this poll did read a pipeline status — it simply could not publish.
# The precedent is Autodev #69's `locked` handling, which does not raise it either
# so the wait stays bounded.
class ReviewInconclusiveDoesNotResetTheWatchClockTest < ActiveSupport::TestCase
  include DatabaseTestHelper

  FakePipeline = Struct.new(:id, :status)
  FakeMr = Struct.new(:state, :head_pipeline)

  # One open MR whose head pipeline is green: the poll takes `handle_green` →
  # `green_first_review`, which is the only caller of `launch_review`.
  class StubClient
    def merge_request(_path, _iid) = FakeMr.new('opened', FakePipeline.new(1, 'success'))
  end

  def setup = setup_database

  def monitor(outcome: :inconclusive, sink: { notify: [], activity: [] })
    mon = PipelineMonitor.allocate
    mon.instance_variable_set(:@client, StubClient.new)
    mon.instance_variable_set(:@project_path, 'g/a')
    mon.instance_variable_set(:@project_config, { 'review_skill' => 'mr-review' })
    mon.instance_variable_set(:@config, {})
    stub_poll_collaborators(mon, sink, outcome)
    stub_abandon_sinks(mon, sink)
    mon
  end

  def stub_poll_collaborators(mon, sink, outcome)
    %i[log log_error].each { |m| mon.define_singleton_method(m) { |*| nil } }
    mon.define_singleton_method(:log_activity) { |_issue, key, **vars| sink[:activity] << [key, vars] }
    mon.define_singleton_method(:claude_available?) { true }
    mon.define_singleton_method(:review_with_skill) { |_| outcome }
  end

  # Every point at which the give-up path leaves the process.
  def stub_abandon_sinks(mon, sink)
    mon.define_singleton_method(:apply_label_attention) { |*| nil }
    mon.define_singleton_method(:apply_label_done) { |*| nil }
    mon.define_singleton_method(:reassign_to_author) { |*| true }
    mon.define_singleton_method(:notify_localized) { |_iid, key, **vars| sink[:notify] << [key, vars] }
    mon.define_singleton_method(:snapshot) { |*| nil }
  end

  def issue(since:)
    Issue.create!(project_path: 'g/a', issue_iid: 1, mr_iid: 7, status: 'checking_pipeline',
                  review_count: 0, review_failure_count: 0, locale: 'fr',
                  checking_pipeline_since: since, issue_author_id: 3)
  end

  def poll(row, outcome: :inconclusive)
    sink = { notify: [], activity: [] }
    monitor(outcome: outcome, sink: sink).send(:check, row)
    sink
  end

  # The clock as data, on a watch young enough that the bound does not fire and
  # clear the column itself: five days in, the row still reads five days old
  # rather than restamped to now.
  def test_an_inconclusive_review_keeps_the_age_the_watch_actually_has
    row = issue(since: 5.days.ago)
    poll(row)

    assert_equal 'checking_pipeline', row.reload.status
    assert_operator row.reload.checking_pipeline_since, :<, 4.days.ago
  end

  # The consequence, which is what the bound is for.
  def test_a_watch_past_the_bound_that_answers_inconclusive_is_still_abandoned
    row = issue(since: 40.days.ago)
    sink = poll(row)

    assert_equal ['done', true, 'pipeline_watch_expired'],
                 [row.reload.status, row.reload.needs_attention, row.reload.attention_reason]
    assert_equal :pipeline_watch_expired, sink[:notify].last.first
  end

  # And the counters still move for nobody: an outcome that published nothing
  # spends no budget (Autodev #71).
  def test_the_abandon_spends_neither_review_budget
    row = issue(since: 40.days.ago)
    poll(row)

    assert_equal [0, 0], [row.reload.review_count, row.reload.review_failure_count]
  end

  # The other half of the bound: a young watch answering `:inconclusive` is handed
  # straight back to `checking_pipeline` and left alone.
  def test_a_young_watch_that_answers_inconclusive_is_left_in_the_watch
    row = issue(since: 2.days.ago)
    sink = poll(row)

    assert_equal 'checking_pipeline', row.reload.status
    assert_empty sink[:notify]
  end

  # A successful review *did* move the row, so restamping the clock is correct
  # there — the preservation must be scoped to the outcome that changed nothing.
  def test_a_successful_review_restarts_the_clock_as_it_always_has
    row = issue(since: 40.days.ago)
    poll(row, outcome: true)

    assert_operator row.reload.checking_pipeline_since, :>, 1.minute.ago
    assert_equal 1, row.reload.review_count
  end
end
