# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/activity_logger'

# Autodev #86 — how `PollDispatcher` feeds `ClarificationWatch`.
#
# The pass is cheap because it reuses what `dispatch_new_issues` already fetched:
# a healthy parked request carries its reposed entry label, so it is in that
# list, and only a row missing from it costs a GitLab read. Two things make that
# true or false, and both live in the dispatcher: the list has to be recorded
# before any filter drops an issue from it, and it has to be absent — not empty —
# when the pass that fetches it did not run.
class ThePollWatchesParkedRequestsTest < Minitest::Test
  include DatabaseTestHelper

  PATH = 'group/project'
  AUTODEV_ID = 7
  PROJECT_CONFIG = { 'path' => PATH, 'labels_todo' => ['To Do'], 'label_doing' => 'Doing',
                     'label_done' => 'Done' }.freeze
  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example' }.freeze

  FakeGlIssue = Struct.new(:iid, :title, :created_at)
  FakeUser = Struct.new(:id)

  # Every GitLab read the watch could make lands here, and none should.
  class RaisingClient
    attr_reader :reads

    def initialize(error = RuntimeError.new('the watch must not read GitLab here'))
      @error = error
      @reads = 0
    end

    def user = FakeUser.new(AUTODEV_ID)

    def issue(_path, _iid)
      @reads += 1
      raise @error
    end
  end

  OTHER_PASSES = %i[dispatch_unassignment dispatch_pipelines dispatch_discussions
                    dispatch_done_unassigned dispatch_dormant_audit dispatch_retries
                    dispatch_infra_recheck].freeze

  def setup
    setup_database
    @logger = StubLogger.new
    GitlabHelpers.instance_variable_set(:@current_user_id, AUTODEV_ID)
  end

  def dispatcher(client:, usage_ok: true, config: CONFIG)
    ivars = { path: PATH, project_config: PROJECT_CONFIG, config: config, logger: @logger, token: 'x',
              client: client, usage_ok: usage_ok }
    Autodev::PollDispatcher.allocate.tap do |d|
      ivars.each { |name, value| d.instance_variable_set(:"@#{name}", value) }
    end
  end

  def parked
    create_issue(project_path: PATH, status: 'needs_clarification', clarification_requested_at: 1.hour.ago)
  end

  # Replaces `passes` with spies recording the order they ran in.
  def spy(dispatcher, passes, ran)
    passes.each { |pass| dispatcher.define_singleton_method(pass) { ran << pass } }
    dispatcher
  end

  # Captures the keywords the watch is built with, and still builds it.
  def capturing_watch_kwargs(&)
    captured = []
    original = Autodev::ClarificationWatch.method(:new)
    Autodev::ClarificationWatch.stub(:new, lambda { |**kwargs|
      captured << kwargs
      original.call(**kwargs)
    }, &)
    captured
  end

  # --- wiring ---------------------------------------------------------------

  # Right after `dispatch_unassignment`: that pass closes the active rows a
  # human took back, this one flags the waiting rows a human took back — the same
  # question for the two populations, asked back to back.
  def test_the_watch_runs_right_after_dispatch_unassignment
    ran = passes_run

    assert_equal ran.index(:dispatch_unassignment) + 1, ran.index(:dispatch_clarification_watch)
  end

  def test_the_watch_does_not_run_in_dry_run
    refute_includes passes_run(config: CONFIG.merge('dry_run' => true)), :dispatch_clarification_watch
  end

  # Every pass a spy, the watch included, in the order `dispatch` ran them.
  def passes_run(config: CONFIG)
    ran = []
    spy(dispatcher(client: RaisingClient.new, config: config),
        OTHER_PASSES + %i[dispatch_new_issues dispatch_clarification_watch], ran).dispatch
    ran
  end

  # Test 3. The gate closed: `dispatch_new_issues` fetched nothing, so an
  # empty list would read every parked row as "gone" and flag them all.
  def test_a_closed_claude_gate_builds_the_watch_with_no_list_and_reads_nothing
    parked
    client = RaisingClient.new
    d = spy(dispatcher(client: client, usage_ok: false), OTHER_PASSES, [])

    captured = capturing_watch_kwargs { d.dispatch }

    assert_equal 1, captured.size
    assert_nil captured.first[:seen_iids]
    assert_equal 0, client.reads
  end

  # Test 4. `too_recent?` drops a fresh ticket from routing, not from the list:
  # a parked row created a minute ago is still reachable, and must not cost a
  # read or be flagged for it.
  def test_the_list_is_recorded_before_the_pickup_delay_filters_it
    issue = parked
    client = RaisingClient.new
    d = new_issues_then_watch(client, created_at: 1.minute.ago, iid: issue.issue_iid)

    assert_includes d.instance_variable_get(:@seen_iids), issue.issue_iid
    assert_equal 0, client.reads
    refute issue.reload.needs_attention
  end

  # The two passes, back to back, over one ticket GitLab returns.
  def new_issues_then_watch(client, created_at:, iid:)
    d = dispatcher(client: client, config: CONFIG.merge('pickup_delay' => 600))
    GitlabHelpers.stub(:fetch_assignee_issues, [FakeGlIssue.new(iid, 'title', created_at.utc.iso8601)]) do
      d.send(:dispatch_new_issues)
      d.send(:dispatch_clarification_watch)
    end
    d
  end

  # Test 13. One row's transport failure stays on that row.
  def test_a_read_timeout_in_the_watch_does_not_stop_the_later_passes
    parked
    client = RaisingClient.new(Net::ReadTimeout.new)

    ran = dispatch_with_an_empty_list(client)

    assert_equal 1, client.reads
    assert_empty %i[dispatch_pipelines dispatch_retries] - ran
  end

  def test_a_read_timeout_in_the_watch_leaves_the_row_untouched
    issue = parked
    dispatch_with_an_empty_list(RaisingClient.new(Net::ReadTimeout.new))

    assert_equal 'needs_clarification', issue.reload.status
    refute issue.needs_attention
  end

  # A cycle whose GitLab list came back empty, so every parked row is read;
  # returns the passes that ran after the watch.
  def dispatch_with_an_empty_list(client)
    ran = []
    d = spy(dispatcher(client: client), OTHER_PASSES, ran)
    d.define_singleton_method(:dispatch_new_issues) { @seen_iids = Set.new }
    d.dispatch
    ran
  end
end
