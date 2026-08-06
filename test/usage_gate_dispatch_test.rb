# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'

# Autodev #46 — a Claude quota outage must not freeze the whole poll cycle.
#
# The gate used to sit on AutodevPollJob, so an exhausted quota skipped every
# dispatch pass, including the ones that only read GitLab and cost no credit
# (pipeline tracking, closure detection, post-completion, budget rechecks). A
# ticket whose remaining path depended only on GitLab stayed frozen for the
# whole outage.
#
# The gate now sits per pass: only what ends in a danger-claude / mr-review
# call is skipped.
class UsageGateDispatchTest < Minitest::Test
  include DatabaseTestHelper

  PROJECT_CONFIG = { 'path' => 'group/project' }.freeze
  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example' }.freeze

  CONSUMING_PASSES = %i[dispatch_new_issues dispatch_discussions].freeze
  OBSERVATION_PASSES = %i[dispatch_pipelines dispatch_unassignment dispatch_done_unassigned
                          dispatch_error_recheck dispatch_retries dispatch_infra_recheck].freeze
  ALL_PASSES = (CONSUMING_PASSES + OBSERVATION_PASSES).freeze

  def setup
    setup_database
    @logger = StubLogger.new
  end

  # `allocate` mirrors the other dispatcher tests: the real initializer builds a
  # GitLab client we don't need here.
  def dispatcher(usage_ok: nil)
    Autodev::PollDispatcher.allocate.tap do |d|
      d.instance_variable_set(:@path, PROJECT_CONFIG['path'])
      d.instance_variable_set(:@project_config, PROJECT_CONFIG)
      d.instance_variable_set(:@config, CONFIG)
      d.instance_variable_set(:@logger, @logger)
      d.instance_variable_set(:@usage_ok, usage_ok) unless usage_ok.nil?
    end
  end

  # Replaces each pass with a spy so `dispatch` reveals which ones it decided to
  # run — the matrix is the behaviour under test, not what each pass does.
  def ran_passes(usage_ok: nil)
    ran = []
    d = dispatcher(usage_ok: usage_ok)
    ALL_PASSES.each { |pass| d.define_singleton_method(pass) { ran << pass } }
    d.dispatch
    ran
  end

  # --- the matrix ---------------------------------------------------------

  def test_a_healthy_quota_runs_every_pass
    assert_equal ALL_PASSES.sort, ran_passes(usage_ok: true).sort
  end

  def test_an_exhausted_quota_skips_the_claude_consuming_passes
    ran = ran_passes(usage_ok: false)

    CONSUMING_PASSES.each { |pass| refute_includes ran, pass }
  end

  # The regression the ticket is about: everything that only reads GitLab keeps
  # running, so pipelines, closures and post-completion still advance.
  def test_an_exhausted_quota_keeps_every_observation_pass
    ran = ran_passes(usage_ok: false)

    OBSERVATION_PASSES.each { |pass| assert_includes ran, pass }
  end

  # A dispatcher built without the flag (older call sites, unit tests) must
  # behave exactly as before: nothing gated.
  def test_an_unset_flag_reads_as_available
    assert_equal ALL_PASSES.sort, ran_passes.sort
  end

  # --- retries: gated by action, not by pass ------------------------------

  def enqueued_retries(usage_ok:)
    calls = []
    IssueProcessJob.stub(:perform_later, ->(*args) { calls << args }) do
      dispatcher(usage_ok: usage_ok).send(:dispatch_retries)
    end
    calls.map(&:last)
  end

  def retryable(status)
    create_issue(status: status, next_retry_at: 1.hour.ago,
                 mr_iid: status == 'error' ? 42 : nil)
  end

  # :retry_stuck re-runs IssueProcessor inline — that is a danger-claude call.
  def test_an_exhausted_quota_defers_retry_stuck
    retryable('pending')

    assert_empty enqueued_retries(usage_ok: false)
  end

  # :retry_errored only fires transitions and restores labels — no Claude.
  def test_an_exhausted_quota_still_enqueues_retry_errored
    retryable('error')

    assert_equal [:retry_errored], enqueued_retries(usage_ok: false)
  end

  def test_a_healthy_quota_enqueues_retry_stuck
    retryable('pending')

    assert_equal [:retry_stuck], enqueued_retries(usage_ok: true)
  end

  # A deferred row keeps its backoff stamp, so the next cycle rediscovers it
  # rather than leaving it orphaned.
  def test_a_deferred_retry_stuck_row_is_left_untouched
    issue = retryable('pending')
    enqueued_retries(usage_ok: false)

    issue.reload

    assert_equal 'pending', issue.status
    refute_nil issue.next_retry_at
  end
end
