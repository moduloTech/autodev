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

  # Fix round 1: `clone_and_checkout` raises `GitError` — a sibling of
  # `ImplementationError` under `AutodevError`, not a subclass — so it escaped
  # `review_with_skill`'s rescue and propagated instead of counting as a review
  # failure. Every scenario above stubs the clone to succeed, which is why
  # nothing caught this.
  def test_a_clone_failure_is_a_review_failure_not_an_escaped_exception
    subject = reviewer(contract_json: nil)
    subject.define_singleton_method(:clone_and_checkout) { |*| raise GitError, 'clone failed' }

    refute subject.send(:review_with_skill, issue)
  end

  # `SkillsInjector.inject` has no rescue of its own, so an `Errno::*` from its
  # `File.write` / `FileUtils.mkdir_p` calls would otherwise escape untyped —
  # same shape as the `GitError` case above, different source.
  def test_a_skill_injection_failure_is_a_review_failure_not_an_escaped_exception
    subject = reviewer(contract_json: nil)

    SkillsInjector.stub(:inject, ->(*) { raise Errno::ENOENT, 'no such file or directory' }) do
      refute subject.send(:review_with_skill, issue)
    end
  end

  # Fix round 2: `review_with_skill` had no `ensure`, so one shallow clone per
  # reviewed ticket accumulated in /tmp until reboot. Both sibling clone paths —
  # `FailureHandler#clone_and_fix` and `FixCycle#execute_fix_cycle` — carry the
  # same line; the spec named `prepare_work_dir` as the idiom and only the
  # cleanup half was dropped. Every scenario above stubs the clone to a no-op,
  # which is why nothing noticed.
  def review_clone_dir = '/tmp/autodev_review_g_a_1'

  def reviewer_that_really_clones(**)
    subject = reviewer(**)
    subject.define_singleton_method(:clone_and_checkout) { |dir, _| FileUtils.mkdir_p(dir) }
    subject
  end

  def test_the_review_clone_is_removed_after_a_successful_review
    json = { verdict: 'approve', summary: '', findings: [] }.to_json
    reviewer_that_really_clones(contract_json: json).send(:review_with_skill, issue)

    refute_path_exists review_clone_dir
  end

  def test_the_review_clone_is_removed_after_a_review_failure
    reviewer_that_really_clones(contract_json: nil, dc_raises: true).send(:review_with_skill, issue)

    refute_path_exists review_clone_dir
  end

  # The `ensure` has to cover the outcome that leaves by exception too — the
  # declared skill missing from the clone, which is the one failure that is
  # *guaranteed* to recur on every poll of that project.
  def test_the_review_clone_is_removed_when_the_declared_skill_is_missing
    subject = reviewer_that_really_clones(contract_json: nil, skill_present: false)

    assert_raises(ConfigError) { subject.send(:review_with_skill, issue) }
    refute_path_exists review_clone_dir
  end

  # Fix round 1, Important: `mr_review_timeout` was stubbed by every scenario
  # above but nothing ever asserted it reached `danger_claude_prompt` — it did
  # not, so a skill-driven review ran under the ordinary 600s `dc_timeout`
  # fallback instead of the review's own (3600s default) timeout.
  def test_the_skill_review_runs_under_the_review_timeout_not_the_default
    subject = reviewer(contract_json: nil)
    subject.define_singleton_method(:mr_review_timeout) { 4200 }
    received_timeout = nil
    subject.define_singleton_method(:danger_claude_prompt) do |*, **kwargs|
      received_timeout = kwargs[:timeout]
      File.write(subject.send(:review_contract_path, 7), { verdict: 'approve', summary: '', findings: [] }.to_json)
      'ok'
    end

    subject.send(:review_with_skill, issue)

    assert_equal 4200, received_timeout
  end
end
