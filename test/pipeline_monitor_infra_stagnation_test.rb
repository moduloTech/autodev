# frozen_string_literal: true

require_relative 'test_helper'
require 'json'
require 'autodev/pipeline_monitor'

# An :infra/deploy verdict used to short-circuit in `infra_skip?` *before* the
# stagnation tracker ran, so a failure that never recovers (e.g. a broken shared
# CI deploy job) polled `checking_pipeline` forever. Issue #116 accumulated
# ~7.6k activity events over 4 days. Its sibling #117 escaped only because an
# extra runner_system_failure job made the verdict :uncertain, which flows into
# the stagnation path and ends as "Livrée (à vérifier)" (done + needs_attention).
# An unrecovered infra failure must reach that same end state.
class PipelineMonitorInfraStagnationTest < Minitest::Test
  # Minimal Issue stand-in: records `update` writes and reflects the
  # stagnation_signatures column back so `stagnated?` sees fresh counts.
  class FakeIssue
    attr_reader :attrs, :issue_iid, :mr_url
    attr_accessor :stagnation_signatures

    def initialize(stagnation_signatures: nil, issue_iid: 16_081, mr_url: 'http://mr')
      @stagnation_signatures = stagnation_signatures
      @issue_iid = issue_iid
      @mr_url = mr_url
      @attrs = {}
    end

    def update(hash)
      @attrs.merge!(hash)
      @stagnation_signatures = hash[:stagnation_signatures] if hash.key?(:stagnation_signatures)
      self
    end

    def status = @attrs[:status]
    def needs_attention = @attrs[:needs_attention]
    def attention_reason = @attrs[:attention_reason]
    def attention_detail = @attrs[:attention_detail]
  end

  # Records the vars each user-facing sink received so tests can assert the
  # infra detail is threaded all the way through.
  def monitor(project_config: {}, config: {})
    sink = { notify: [], activity: [] }
    m = PipelineMonitor.allocate.tap do |mon|
      mon.instance_variable_set(:@project_config, project_config)
      mon.instance_variable_set(:@config, config)
      # External boundaries (GitLab label + notification + activity log).
      mon.define_singleton_method(:log) { |*| nil }
      mon.define_singleton_method(:log_activity) { |_issue, key, **vars| sink[:activity] << [key, vars] }
      mon.define_singleton_method(:apply_label_done) { |*| nil }
      mon.define_singleton_method(:notify_localized) { |_iid, key, **vars| sink[:notify] << [key, vars] }
    end
    [m, sink]
  end

  # deploy job carrying a concrete failure_reason + GitLab URL, the shape the
  # infra path formats into the operator-facing detail string.
  def deploy_jobs
    [{ 'name' => 'deploy_review', 'stage' => 'deploy', 'failure_reason' => 'script_failure',
       'web_url' => 'http://gitlab/job/42' }]
  end

  # The detail string format_failure_detail produces for `deploy_jobs`.
  BAIL_DETAIL = 'deploy_review (script_failure) — http://gitlab/job/42'

  # Runs infra_skip? on an issue already sitting at the (threshold-3) stagnation
  # count, so the call bails out. Returns [monitor, issue, sink, consumed?].
  def run_bail_out
    m, sink = monitor(config: { 'stagnation_threshold' => 3 })
    sig = m.send(:compute_pipeline_signature, deploy_jobs)
    issue = FakeIssue.new(stagnation_signatures: JSON.generate('pipeline' => { 'signature' => sig, 'count' => 3 }))
    [issue, sink, m.send(:infra_skip?, issue, { verdict: :infra }, deploy_jobs)]
  end

  def test_persistent_infra_failure_bails_out_as_delivered_needs_attention
    issue, _sink, consumed = run_bail_out

    assert consumed, 'infra_skip? must still consume the poll cycle'
    assert_equal ['done', true, 'stagnation_pipeline'],
                 [issue.status, issue.needs_attention, issue.attention_reason]
  end

  def test_bail_out_persists_the_failing_job_detail_on_the_issue
    issue, = run_bail_out

    assert_equal BAIL_DETAIL, issue.attention_detail
  end

  def test_bail_out_threads_the_detail_into_notification_and_activity
    _issue, sink, = run_bail_out

    assert_equal [:stagnation_pipeline, BAIL_DETAIL], last_key_and_detail(sink[:notify])
    assert_equal [:stagnation_pipeline, BAIL_DETAIL], last_key_and_detail(sink[:activity])
  end

  def last_key_and_detail(entries)
    key, vars = entries.last
    [key, vars[:detail]]
  end

  def test_infra_failure_below_threshold_keeps_waiting_and_counts
    m, = monitor(config: { 'stagnation_threshold' => 3 })
    sig = m.send(:compute_pipeline_signature, deploy_jobs)
    issue = FakeIssue.new(stagnation_signatures: JSON.generate('pipeline' => { 'signature' => sig, 'count' => 1 }))

    consumed = m.send(:infra_skip?, issue, { verdict: :infra }, deploy_jobs)

    assert consumed
    refute_equal 'done', issue.status
    assert_equal 2, JSON.parse(issue.stagnation_signatures).dig('pipeline', 'count')
  end

  def test_waiting_activity_line_carries_the_detail
    m, sink = monitor(config: { 'stagnation_threshold' => 3 })

    m.send(:infra_skip?, FakeIssue.new, { verdict: :infra }, deploy_jobs)

    assert_equal [:pipeline_infra, BAIL_DETAIL], last_key_and_detail(sink[:activity])
  end

  def test_format_failure_detail_joins_several_jobs_and_tolerates_missing_fields
    m, = monitor
    jobs = [{ 'name' => 'deploy_review', 'failure_reason' => 'script_failure' },
            { 'name' => 'werf_render' }] # no reason/url

    assert_equal 'deploy_review (script_failure), werf_render', m.send(:format_failure_detail, jobs)
  end

  def test_non_infra_verdict_is_not_skipped
    m, = monitor
    issue = FakeIssue.new

    refute m.send(:infra_skip?, issue, { verdict: :code }, [{ 'name' => 'rspec' }])
  end
end
