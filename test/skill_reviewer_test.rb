# frozen_string_literal: true

require_relative 'rails_helper'
require 'ostruct'

# The skill judges and stops; autodev posts (Autodev #74). What counts as a
# review failure is the whole point of this file.
class SkillReviewerTest < ActiveSupport::TestCase
  # A logger that discards everything. Not in the brief's snippet, but
  # `prepare_review_clone` calls the real `SkillsInjector.inject`, which logs
  # through `@logger` — left unset, `mon.instance_variable_set` never touches
  # it, so the very first scenario crashed on `NoMethodError: undefined method
  # 'info' for nil` before reaching any of this file's assertions. Mirrors the
  # `NullLogger` in test/review_publisher_test.rb, kept local for the same
  # stated reason: this file and that one must not race on a shared file.
  class NullLogger
    %i[info warn error debug].each { |level| define_method(level) { |*| nil } }
  end

  # Full construction is covered by the integration test in Task 5; here the
  # collaborators are stubbed so each failure mode is isolated.
  #
  # Split from a single method into this plus the two stub_* helpers below
  # purely to fit RuboCop's Metrics/MethodLength (not in the brief's snippet) —
  # behaviour is unchanged, every stub the brief specifies is still installed.
  def reviewer(contract_json:, dc_raises: false, skill: 'mr-review', skill_present: true)
    mon = PipelineMonitor.allocate
    mon.instance_variable_set(:@project_path, 'g/a')
    mon.instance_variable_set(:@project_config, { 'review_skill' => skill })
    mon.instance_variable_set(:@logger, NullLogger.new)
    %i[log log_error].each { |m| mon.define_singleton_method(m) { |*| nil } }
    stub_collaborators!(mon, skill_present)
    stub_danger_claude_prompt!(mon, dc_raises: dc_raises, contract_json: contract_json)
    mon.define_singleton_method(:publish_review) { |*| { posted: 0, demoted: 0 } }
    mon
  end

  def stub_collaborators!(mon, skill_present)
    mon.define_singleton_method(:clone_and_checkout) { |*| true }
    mon.define_singleton_method(:skill_available?) { |*| skill_present }
    mon.define_singleton_method(:mr_review_timeout) { 600 }
  end

  def stub_danger_claude_prompt!(mon, dc_raises:, contract_json:)
    mon.define_singleton_method(:danger_claude_prompt) do |*|
      raise ImplementationError, 'dc failed' if dc_raises

      File.write(mon.send(:review_contract_path, 7), contract_json) if contract_json
      'ok'
    end
  end

  def issue = OpenStruct.new(issue_iid: 1, mr_iid: 7, branch_name: 'b', locale: 'fr') # rubocop:disable Style/OpenStructUse

  def test_a_clean_review_is_a_success
    json = { verdict: 'approve', summary: '', findings: [] }.to_json

    assert reviewer(contract_json: json).send(:review_with_skill, issue)
  end

  def test_a_missing_contract_file_is_a_failure
    refute reviewer(contract_json: nil).send(:review_with_skill, issue)
  end

  def test_an_off_schema_contract_is_a_failure
    refute reviewer(contract_json: '{"verdict":"lgtm"}').send(:review_with_skill, issue)
  end

  def test_a_danger_claude_crash_is_a_failure
    refute reviewer(contract_json: nil, dc_raises: true).send(:review_with_skill, issue)
  end

  def test_absent_diff_refs_are_inconclusive_not_a_success
    json = { verdict: 'changes_requested', summary: 'S',
             findings: [{ file: 'a.rb', line: 1, severity: 'error', body: 'b' }] }.to_json
    subject = reviewer(contract_json: json)
    subject.define_singleton_method(:publish_review) { |*| nil }

    assert_equal :inconclusive, subject.send(:review_with_skill, issue)
  end

  def test_a_declared_skill_missing_from_the_clone_is_named_not_silently_replaced
    subject = reviewer(contract_json: nil, skill_present: false)
    error = assert_raises(ConfigError) { subject.send(:review_with_skill, issue) }
    assert_match(/mr-review/, error.message)
  end
end
