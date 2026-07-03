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
  end

  def monitor(project_config: {}, config: {})
    PipelineMonitor.allocate.tap do |m|
      m.instance_variable_set(:@project_config, project_config)
      m.instance_variable_set(:@config, config)
      # External boundaries (GitLab label + notification + activity log).
      m.define_singleton_method(:log) { |*| nil }
      m.define_singleton_method(:log_activity) { |*, **| nil }
      m.define_singleton_method(:apply_label_done) { |*| nil }
      m.define_singleton_method(:notify_localized) { |*, **| nil }
    end
  end

  def deploy_jobs = [{ 'name' => 'deploy_review', 'stage' => 'deploy' }]

  def test_persistent_infra_failure_bails_out_as_delivered_needs_attention
    m = monitor(config: { 'stagnation_threshold' => 3 })
    sig = m.send(:compute_pipeline_signature, deploy_jobs)
    issue = FakeIssue.new(stagnation_signatures: JSON.generate('pipeline' => { 'signature' => sig, 'count' => 3 }))

    consumed = m.send(:infra_skip?, issue, { verdict: :infra }, deploy_jobs)

    assert consumed, 'infra_skip? must still consume the poll cycle'
    assert_equal ['done', true, 'stagnation_pipeline'],
                 [issue.status, issue.needs_attention, issue.attention_reason]
  end

  def test_infra_failure_below_threshold_keeps_waiting_and_counts
    m = monitor(config: { 'stagnation_threshold' => 3 })
    sig = m.send(:compute_pipeline_signature, deploy_jobs)
    issue = FakeIssue.new(stagnation_signatures: JSON.generate('pipeline' => { 'signature' => sig, 'count' => 1 }))

    consumed = m.send(:infra_skip?, issue, { verdict: :infra }, deploy_jobs)

    assert consumed
    refute_equal 'done', issue.status
    assert_equal 2, JSON.parse(issue.stagnation_signatures).dig('pipeline', 'count')
  end

  def test_non_infra_verdict_is_not_skipped
    m = monitor
    issue = FakeIssue.new

    refute m.send(:infra_skip?, issue, { verdict: :code }, [{ 'name' => 'rspec' }])
  end
end
