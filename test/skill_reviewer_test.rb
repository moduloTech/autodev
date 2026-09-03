# frozen_string_literal: true

require_relative 'rails_helper'
require 'ostruct'

# The skill judges and stops; autodev posts (Autodev #74). What counts as a
# review failure is the whole point of this file.
class SkillReviewerTest < ActiveSupport::TestCase # rubocop:disable Metrics/ClassLength
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

  # The declared skill as GitLab holds it on the branch that decides
  # (Autodev #89). Which branch that is, and what is materialised from it, is the
  # subject of `test/review_reads_the_skill_from_the_target_branch_test.rb`; here
  # it only has to answer, so each failure mode below stays isolated.
  class FakeGitlab
    Blob = Struct.new(:type, :path)

    def initialize(present:)
      @present = present
    end

    def get_file(_path, file, _ref)
      raise not_found unless @present && file.end_with?('SKILL.md')

      Struct.new(:file_path).new(file)
    end

    def commit(_path, _ref) = Struct.new(:id).new('deadbeef')
    def file_contents(_path, file, _ref) = "# #{File.basename(File.dirname(file))}"

    # The ref the skill is read from is the target the merge request under review
    # goes into (Autodev #91, applied to the review by the round that followed
    # #89); which branch that is is the other file's subject, so this only has to
    # answer.
    def merge_request(_path, iid) = Struct.new(:iid, :state, :target_branch).new(iid, 'opened', 'main')

    # `blobs_under` pairs `per_page: 100` with `.auto_paginate`, as every other
    # list read in this repository does, so the answer is the gem's own response
    # object rather than an Array.
    def tree(_path, options) = Gitlab::PaginatedResponse.new([Blob.new('blob', "#{options[:path]}/SKILL.md")])

    private

    def not_found
      request = Struct.new(:base_uri, :path).new('https://gitlab.example', '/api/v4')
      Gitlab::Error::NotFound.new(Struct.new(:code, :parsed_response, :request).new(404, {}, request))
    end
  end

  # Full construction is covered by the integration test in Task 5; here the
  # collaborators are stubbed so each failure mode is isolated.
  #
  # Split from a single method into this plus the two stub_* helpers below
  # purely to fit RuboCop's Metrics/MethodLength (not in the brief's snippet) —
  # behaviour is unchanged, every stub the brief specifies is still installed.
  def reviewer(contract_json:, dc_raises: false, skill: 'mr-review', skill_present: true)
    mon = PipelineMonitor.allocate
    configure!(mon, skill: skill, skill_present: skill_present)
    %i[log log_error].each { |m| mon.define_singleton_method(m) { |*| nil } }
    stub_collaborators!(mon, skill_present)
    stub_danger_claude_prompt!(mon, dc_raises: dc_raises, contract_json: contract_json)
    mon.define_singleton_method(:publish_review) { |*| { posted: 0, demoted: 0 } }
    mon
  end

  # `target_branch` is what decides the review since Autodev #89, so it has to be
  # configured for the reviewer to have a ref at all.
  def configure!(mon, skill:, skill_present:)
    mon.instance_variable_set(:@project_path, 'g/a')
    mon.instance_variable_set(:@client, FakeGitlab.new(present: skill_present))
    mon.instance_variable_set(:@project_config,
                              { 'path' => 'g/a', 'target_branch' => 'main', 'review_skill' => skill })
    mon.instance_variable_set(:@logger, NullLogger.new)
  end

  def stub_collaborators!(mon, skill_present)
    mon.define_singleton_method(:clone_and_checkout) { |*| true }
    mon.define_singleton_method(:skill_available?) { |*| skill_present }
    mon.define_singleton_method(:mr_review_timeout) { 600 }
  end

  # `dc_raises` is either `true` (a generic crash) or a String — the message
  # to raise `ImplementationError` with, so a scenario can replay a specific
  # production failure (Autodev #107's Docker 500 fixture below).
  def stub_danger_claude_prompt!(mon, dc_raises:, contract_json:)
    mon.define_singleton_method(:danger_claude_prompt) do |*|
      raise ImplementationError, (dc_raises.is_a?(String) ? dc_raises : 'dc failed') if dc_raises

      File.write(mon.send(:review_contract_path, 7), contract_json) if contract_json
      'ok'
    end
  end

  def issue = OpenStruct.new(issue_iid: 1, mr_iid: 7, branch_name: 'b', locale: 'fr') # rubocop:disable Style/OpenStructUse

  def test_a_clean_review_is_a_success
    json = { verdict: 'approve', summary: '', findings: [] }.to_json

    assert reviewer(contract_json: json).send(:review_with_skill, issue)
  end

  # A missing or off-schema contract is `:unusable_output` (Autodev #107): the
  # one cause that is about *this* merge request meeting *this* skill, so it
  # is the only one left that still spends `review_failure_count` — unchanged
  # from before this ticket, only named now instead of collapsing into `false`.
  def test_a_missing_contract_file_is_unusable_output
    assert_equal :unusable_output, reviewer(contract_json: nil).send(:review_with_skill, issue)
  end

  def test_an_off_schema_contract_is_unusable_output
    assert_equal :unusable_output,
                 reviewer(contract_json: '{"verdict":"lgtm"}').send(:review_with_skill, issue)
  end

  # A `danger_claude_prompt` crash — the container runtime, a timeout, a crash
  # — is `:tool_unavailable` (Autodev #107): nothing about it is a statement on
  # the merge request, so `dispatch_review_outcome` must not spend the budget
  # on it. The Docker 500 fixture is the measured cause: bobette's engine
  # refused every `danger-claude` call in `ensure_volume` for nine hours on an
  # API-version mismatch, and burned five review failures on
  # powerpanne/core#16030 in the middle of it.
  def test_a_docker_outage_is_tool_unavailable_not_a_review_failure
    docker500 = 'Error response from daemon: client version 1.54 is too old. ' \
                'Minimum supported API version is 1.55 (ensure_volume danger-claude)'

    outcome = reviewer(contract_json: nil, dc_raises: docker500).send(:review_with_skill, issue)

    assert_equal :tool_unavailable, outcome
  end

  def test_a_generic_danger_claude_crash_is_also_tool_unavailable
    assert_equal :tool_unavailable, reviewer(contract_json: nil, dc_raises: true).send(:review_with_skill, issue)
  end

  def test_absent_diff_refs_are_inconclusive_not_a_success
    json = { verdict: 'changes_requested', summary: 'S',
             findings: [{ file: 'a.rb', line: 1, severity: 'error', body: 'b' }] }.to_json
    subject = reviewer(contract_json: json)
    subject.define_singleton_method(:publish_review) { |*| nil }

    assert_equal :inconclusive, subject.send(:review_with_skill, issue)
  end

  # "Missing from the branch that decides", since Autodev #89 — the message names
  # the ref, because "missing" without "from where" is what made the production
  # give-up of 28/08 unreadable.
  def test_a_declared_skill_missing_from_the_target_branch_is_named_not_silently_replaced
    subject = reviewer(contract_json: nil, skill_present: false)
    error = assert_raises(ConfigError) { subject.send(:review_with_skill, issue) }
    assert_match(/mr-review.*'main'/m, error.message)
  end

  # Fix round 1: `clone_and_checkout` raises `GitError` — a sibling of
  # `ImplementationError` under `AutodevError`, not a subclass — so it escaped
  # `review_with_skill`'s rescue and propagated instead of being read as an
  # outcome. Every scenario above stubs the clone to succeed, which is why
  # nothing caught this.
  #
  # Autodev #107 reverses what it *becomes*: `clone_for_review` still catches
  # every `StandardError` so a network hiccup and a deleted branch both arrive
  # here the same way, but the outcome is now `:clone_failed`, not a spent
  # review failure — a clone failure is not evidence about the merge request
  # (Autodev #96 measured ~9% of GitLab reads failing from bobette by TCP
  # refusal, in bursts).
  def test_a_clone_failure_is_clone_failed_not_a_spent_review_failure
    subject = reviewer(contract_json: nil)
    subject.define_singleton_method(:clone_and_checkout) { |*| raise GitError, 'clone failed' }

    assert_equal :clone_failed, subject.send(:review_with_skill, issue)
  end

  # `SkillsInjector.inject` has no rescue of its own, so an `Errno::*` from its
  # `File.write` / `FileUtils.mkdir_p` calls would otherwise escape untyped —
  # same shape as the `GitError` case above, different source. It is a local
  # environment failure, not a clone failure and not a statement on the merge
  # request, so it joins `:tool_unavailable`.
  def test_a_skill_injection_failure_is_tool_unavailable_not_an_escaped_exception
    subject = reviewer(contract_json: nil)

    SkillsInjector.stub(:inject, ->(*) { raise Errno::ENOENT, 'no such file or directory' }) do
      assert_equal :tool_unavailable, subject.send(:review_with_skill, issue)
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
