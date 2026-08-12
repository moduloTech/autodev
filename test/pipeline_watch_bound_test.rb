# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/pipeline_monitor'

# Nothing bounded a pipeline watch in time (Autodev #53). `dispatch_pipelines`
# re-enqueues every `checking_pipeline` row on every cycle, and the only
# existing bound — stagnation — is fed exclusively from `handle_red`, so a
# pipeline that is never `failed` (`manual`, `canceled`, `skipped`, or a head
# pipeline stuck at `created`) accumulates no signature and is never given up.
# Production issue #15894 polled 29 773 times.
#
# The bound is checked *after* the poll ran and only if the poll left the row
# where it was, so "the poll ended without a transition" is a condition rather
# than an enumeration of the branches that go nowhere — including the ones
# Autodev #51 is currently rewriting.
class PipelineWatchBoundTest < Minitest::Test
  # Records `update` writes; `status` reflects them so the post-dispatch guard
  # sees what the real AASM object would carry.
  #
  # `abandon!` stands in for the AASM event the give-up path fires since Autodev
  # #60, including the `stamp_pipeline_watch!` callback that clears the watch
  # clock — the reason the give-up path no longer clears it by hand. The
  # from-state restriction is reproduced too: the real event only transitions out
  # of `checking_pipeline` / `fixing_discussions`. That the real machine behaves
  # this way is pinned in test/database_pipeline_green_test.rb and
  # test/issue_abandonment_test.rb, against real AR rows.
  class FakeIssue
    ABANDONABLE = %w[checking_pipeline fixing_discussions].freeze

    attr_reader :attrs, :issue_iid, :mr_iid, :mr_url, :checking_pipeline_since, :issue_author_id

    def initialize(status: 'checking_pipeline', since: nil)
      @attrs = { status: status }
      @checking_pipeline_since = since
      @issue_iid = 15_894
      @mr_iid = 42
      @mr_url = 'http://gitlab/mr/42'
      @issue_author_id = 7
    end

    def update(hash)
      @attrs.merge!(hash)
      @checking_pipeline_since = hash[:checking_pipeline_since] if hash.key?(:checking_pipeline_since)
      self
    end

    # rubocop:disable Naming/PredicateMethod -- mirrors AASM's bang event, which
    # returns whether the transition happened.
    def abandon!
      return false unless ABANDONABLE.include?(status)

      @attrs[:status] = 'done'
      @checking_pipeline_since = nil
      true
    end
    # rubocop:enable Naming/PredicateMethod

    def status = @attrs[:status]
    def needs_attention = @attrs[:needs_attention]
    def attention_reason = @attrs[:attention_reason]
    def finished_at = @attrs[:finished_at]
  end

  def monitor(project_config: {}, config: {})
    sink = { notify: [], activity: [], labels: [], reassigned: [] }
    mon = PipelineMonitor.allocate
    mon.instance_variable_set(:@project_config, project_config)
    mon.instance_variable_set(:@config, config)
    stub_boundaries(mon, sink)
    [mon, sink]
  end

  # Every point at which the give-up path leaves the process: the GitLab label,
  # the assignee, the issue comment and the activity log.
  def stub_boundaries(mon, sink)
    mon.define_singleton_method(:log) { |*| nil }
    mon.define_singleton_method(:log_activity) { |_issue, key, **vars| sink[:activity] << [key, vars] }
    mon.define_singleton_method(:apply_label_done) { |iid| sink[:labels] << iid }
    mon.define_singleton_method(:notify_localized) { |_iid, key, **vars| sink[:notify] << [key, vars] }
    mon.define_singleton_method(:reassign_to_author) { |issue| sink[:reassigned] << issue.issue_iid }
  end

  # Returns the sink; the outcome is read off the issue, which is what the
  # rest of the system reads too.
  def abandon(issue, project_config: {}, config: {})
    mon, sink = monitor(project_config: project_config, config: config)
    mon.send(:abandon_expired_watch, issue)
    sink
  end

  def expired_issue(days: 20) = FakeIssue.new(since: days.days.ago)

  def test_a_young_watch_is_left_alone
    issue = FakeIssue.new(since: 3.days.ago)
    sink = abandon(issue)

    assert_equal 'checking_pipeline', issue.status
    assert_empty sink[:notify]
  end

  def test_an_expired_watch_is_given_up_as_delivered_needing_a_check
    issue = expired_issue
    abandon(issue)

    assert_equal ['done', true, 'pipeline_watch_expired'],
                 [issue.status, issue.needs_attention, issue.attention_reason]
  end

  def test_giving_up_stamps_finished_at_and_clears_the_clock
    issue = expired_issue
    abandon(issue)

    refute_nil issue.finished_at
    assert_nil issue.checking_pipeline_since
  end

  def test_giving_up_applies_the_done_label
    issue = expired_issue

    assert_equal [15_894], abandon(issue)[:labels]
  end

  # Autodev #60 aligned the three give-up paths onto one reassignment policy: an
  # abandon hands the ticket back to its author, because a ticket left assigned to
  # autodev is invisible to everybody. This path used to leave it on autodev.
  def test_giving_up_hands_the_ticket_back_to_its_author
    issue = expired_issue

    assert_equal [15_894], abandon(issue)[:reassigned]
  end

  def test_giving_up_posts_a_gitlab_note_carrying_the_age
    issue = expired_issue
    key, vars = abandon(issue)[:notify].last

    assert_equal :pipeline_watch_expired, key
    assert_equal [14, 'http://gitlab/mr/42'], [vars[:days], vars[:mr_url]]
  end

  def test_giving_up_records_an_activity_entry
    issue = expired_issue
    key, vars = abandon(issue)[:activity].last

    assert_equal([:pipeline_watch_expired, 14], [key, vars[:days]])
  end

  # The whole reason the call sits after `dispatch_pipeline`: a poll that
  # resolved must never be pre-empted, however old the watch is.
  def test_a_poll_that_transitioned_is_never_abandoned
    issue = FakeIssue.new(status: 'reviewing', since: 40.days.ago)
    sink = abandon(issue)

    assert_equal 'reviewing', issue.status
    assert_empty sink[:notify]
  end

  # A row that arrived by `update_all` (revive_stalled!, reset_for_retry!)
  # carries no stamp until PollTracker seeds it — it must not be abandoned on
  # the spot.
  def test_a_row_without_a_stamp_is_left_alone
    issue = FakeIssue.new(since: nil)

    assert_equal 'checking_pipeline', issue.status
    assert_empty abandon(issue)[:notify]
  end

  def test_the_bound_can_be_disabled
    issue = FakeIssue.new(since: 400.days.ago)

    assert_empty abandon(issue, config: { 'pipeline_watch_max_days' => 0 })[:notify]
    assert_equal 'checking_pipeline', issue.status
  end

  def test_a_project_value_overrides_the_global_one
    issue = FakeIssue.new(since: 20.days.ago)
    sink = abandon(issue, project_config: { 'pipeline_watch_max_days' => 30 },
                          config: { 'pipeline_watch_max_days' => 14 })

    assert_empty sink[:notify]
    assert_equal 'checking_pipeline', issue.status
  end

  def test_the_configured_threshold_is_reported_in_the_message
    issue = FakeIssue.new(since: 40.days.ago)
    sink = abandon(issue, config: { 'pipeline_watch_max_days' => 30 })

    assert_equal 30, sink[:notify].last.last[:days]
  end

  def test_the_baked_default_is_fourteen_days
    assert_equal 14, Config::DEFAULTS['pipeline_watch_max_days']
  end
end
