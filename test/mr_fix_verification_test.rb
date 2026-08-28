# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/mr_fixer'

# Autodev #79 — resolving a discussion is a claim, and it may not be made by the
# agent that produced the correction.
#
# `MrFixer` used to run, per unresolved thread: `danger-claude -p` (the fix),
# `danger-claude -c` (the commit), then `resolve_merge_request_discussion`. The
# resolution IS the statement that the review point is dealt with, and nothing
# looked at the correction before it was made. A fix aimed at the wrong thing,
# or one that removes the symptom, closed the thread exactly like a good one —
# and the only thing downstream is the pipeline, which answers a different
# question ("do the tests pass").
#
# The answer is the one PowerPanne's own review skill prescribes for its triage:
# a targeted pass over a *named* defect and the diff that claims to fix it. That
# is not the adversarial pass, which the same skill forbids re-running on a
# corrected commit because it produces findings on any code and never converges;
# checking one named claim is bounded by construction, which is why the skill
# allows one and refuses the other.
#
# What the sections below pin is the invariant, not the mechanism: **autodev
# never resolves a discussion it has not verified.** Every way the check can fail
# to say "addressed" — including the check itself not running — leaves the thread
# open, which is the conservative direction: an open thread is re-read next round
# and, if nothing moves, `stagnation_threshold` rounds later the ticket is handed
# to a human. A wrongly resolved thread has no such recovery.
module FixVerificationHarness
  DIFF = "diff --git a/app/x.rb b/app/x.rb\n+  guard_clause\n"

  # A `MrFixer` with the collaborators the fix loop reads, and stubs for
  # everything around the one decision under test. Real: the budget resolution,
  # the diff capture, the contract parsing and the resolve decision. Stubbed: the
  # clone, the two danger-claude calls of the fix itself, and the GitLab write.
  #
  # `answer` is what the verification pass writes into its contract file (nil =
  # writes nothing, i.e. the pass ran and produced no contract).
  def fixer(project_config: {}, config: {}, answer: nil, diff: DIFF, raises: nil)
    MrFixer.allocate.tap do |fix|
      configure(fix, project_config, config)
      silence(fix)
      stub_fix_steps(fix, diff)
      stub_verification(fix, answer, raises)
    end
  end

  def sink
    @sink ||= { activity: [], resolved: [], prompts: [] }
  end

  def contract_path
    @contract_path ||= File.join(tmp_dir, 'contract.json')
  end

  def tmp_dir
    @tmp_dir ||= Dir.mktmpdir('autodev-fix-verification')
  end

  def discussions(count)
    Array.new(count) { |i| { id: "thread-#{i}", title: "comment #{i}", notes: [] } }
  end

  def run_round(fix, list)
    fix.send(:fix_each_discussion, list, '/tmp/work', 'autodev/1', 42, { target_branch: 'main' })
  end

  def addressed = JSON.generate(verdict: 'addressed', reason: 'the guard clause was added')
  def not_addressed = JSON.generate(verdict: 'not_addressed', reason: 'the diff renames a variable')

  private

  def configure(fix, project_config, config)
    fix.instance_variable_set(:@project_config, project_config)
    fix.instance_variable_set(:@config, config)
    fix.instance_variable_set(:@project_path, 'group/project')
    fix.instance_variable_set(:@fix_issue, nil)
  end

  def silence(fix)
    bucket = sink
    %i[log log_error].each { |noop| fix.define_singleton_method(noop) { |*| nil } }
    fix.define_singleton_method(:log_activity) { |_issue, key, **vars| bucket[:activity] << [key, vars] }
  end

  # The fix half of one thread: the prompt, the commit, the GitLab write, and the
  # two `git` questions the verification asks around them.
  def stub_fix_steps(fix, diff)
    bucket = sink
    fix.define_singleton_method(:format_discussion) { |d, **| "thread body of #{d[:id]}" }
    fix.define_singleton_method(:run_fix_prompt) { |*| nil }
    fix.define_singleton_method(:danger_claude_commit) { |*| nil }
    fix.define_singleton_method(:resolve_discussion) { |_mr_iid, id| bucket[:resolved] << id }
    fix.define_singleton_method(:run_cmd_status) do |cmd, **|
      cmd.include?('rev-parse') ? ['sha-before', '', true] : [diff, '', true]
    end
  end

  # The verification pass itself: one `danger-claude -p` in a fresh session that
  # writes a contract file. The paths are overridden so the stub can write where
  # the code will read.
  def stub_verification(fix, answer, raises)
    bucket = sink
    path = contract_path
    fix.define_singleton_method(:verification_contract_path) { |_d| path }
    fix.define_singleton_method(:verification_diff_path) { |_d| File.join(File.dirname(path), 'fix.diff') }
    fix.define_singleton_method(:danger_claude_prompt) do |_work_dir, prompt, **opts|
      bucket[:prompts] << [prompt, opts]
      raise raises if raises

      File.write(path, answer) if answer
      ''
    end
  end
end

# --- 1. the invariant ------------------------------------------------------

class MrFixVerificationTest < Minitest::Test
  include FixVerificationHarness

  def teardown
    FileUtils.rm_rf(@tmp_dir) if @tmp_dir
  end

  def test_a_verified_correction_resolves_the_thread
    fix = fixer(answer: addressed)

    resolved = run_round(fix, discussions(1))

    assert_equal ['thread-0'], sink[:resolved]
    assert_equal 1, resolved.size, 'the round reports what it actually resolved'
  end

  # The whole ticket: the correction was made, and the pass says it misses the
  # point. The thread stays open, so the next round re-reads it.
  def test_a_correction_judged_off_target_leaves_the_thread_open
    fix = fixer(answer: not_addressed)

    resolved = run_round(fix, discussions(1))

    assert_empty sink[:resolved], 'a correction nothing verified may not close its thread'
    assert_empty resolved
    assert_includes sink[:activity].map(&:first), :discussion_unverified
  end

  # The reviewer's own words travel to the activity log — "not addressed" alone
  # tells a reader nothing about what to do next.
  def test_the_verdicts_reason_reaches_the_activity_log
    fix = fixer(answer: not_addressed)
    run_round(fix, discussions(1))

    _key, vars = sink[:activity].find { |key, _| key == :discussion_unverified }

    assert_equal 'the diff renames a variable', vars[:reason]
    assert_equal 'comment 0', vars[:title]
  end

  # The most blatant instance of the defect: danger-claude committed nothing at
  # all, and the thread was resolved anyway. No diff, no claim — and no call
  # spent asking about an empty diff.
  def test_a_correction_that_changed_nothing_leaves_the_thread_open
    fix = fixer(diff: '')

    run_round(fix, discussions(1))

    assert_empty sink[:resolved]
    assert_empty sink[:prompts], 'an empty diff is answered without spending a verification call'
    assert_includes sink[:activity].map(&:first), :discussion_unchanged
  end

  # The #62 direction, applied to a danger-claude call instead of a GitLab read:
  # the neutral value here is "addressed", which is the good news, so a check
  # that could not be performed must not produce it.
  def test_a_verification_that_crashed_leaves_the_thread_open
    fix = fixer(raises: ImplementationError.new('danger-claude -p failed'))

    run_round(fix, discussions(1))

    assert_empty sink[:resolved]
    assert_includes sink[:activity].map(&:first), :discussion_unverifiable
  end

  def test_a_missing_contract_file_leaves_the_thread_open
    fix = fixer(answer: nil)

    run_round(fix, discussions(1))

    assert_empty sink[:resolved]
    assert_includes sink[:activity].map(&:first), :discussion_unverifiable
  end

  def test_an_off_schema_contract_leaves_the_thread_open
    fix = fixer(answer: JSON.generate(verdict: 'probably'))

    run_round(fix, discussions(1))

    assert_empty sink[:resolved]
    assert_includes sink[:activity].map(&:first), :discussion_unverifiable
  end

  # A quota outage is not a verdict on the correction either — it is the same
  # class every other `danger_claude_prompt` call site lets travel to
  # `execute_fix_cycle`, which parks the row with a retry instead of closing
  # anything.
  def test_a_quota_outage_travels_instead_of_becoming_a_verdict
    fix = fixer(raises: RateLimitError.new('usage limit reached'))

    assert_raises(RateLimitError) { run_round(fix, discussions(1)) }
    assert_empty sink[:resolved]
  end

  # The pass judges one named claim against one diff. It must not be the session
  # that produced the fix, or it is grading its own work, and it must not carry
  # the mr-fixer agent, whose whole instruction is how to correct.
  def test_the_verification_runs_in_a_fresh_session
    fix = fixer(answer: addressed)
    run_round(fix, discussions(1))

    _prompt, opts = sink[:prompts].first

    assert_nil opts[:resume], 'the verifier may not resume the fixer session'
    assert_nil opts[:agent]
  end
end

# --- 2. the cost bound -----------------------------------------------------

# One verification per thread is one extra danger-claude call per thread, and a
# production round carries up to 18. `fix_verification_max` caps what one round
# spends; the threads past the cap are simply not attempted, so the invariant
# holds exactly rather than being suspended for the overflow.
class MrFixVerificationBudgetTest < Minitest::Test
  include FixVerificationHarness

  def teardown
    FileUtils.rm_rf(@tmp_dir) if @tmp_dir
  end

  def test_the_budget_caps_what_one_round_attempts
    fix = fixer(project_config: { 'fix_verification_max' => 2 }, answer: addressed)

    resolved = run_round(fix, discussions(5))

    assert_equal 2, resolved.size
    assert_equal 2, sink[:prompts].size, 'at most one verification call per attempted thread'
    assert_equal %w[thread-0 thread-1], sink[:resolved]
  end

  def test_the_deferred_threads_are_announced
    fix = fixer(project_config: { 'fix_verification_max' => 2 }, answer: addressed)
    run_round(fix, discussions(5))

    _key, vars = sink[:activity].find { |key, _| key == :discussions_deferred }

    assert_equal 3, vars[:count]
  end

  def test_a_round_within_the_budget_defers_nothing
    fix = fixer(project_config: { 'fix_verification_max' => 10 }, answer: addressed)
    run_round(fix, discussions(3))

    refute_includes sink[:activity].map(&:first), :discussions_deferred
  end

  # 0 is the sentinel, exactly as it is for `pipeline_watch_max_days`: the check
  # is switched off and the round behaves as it did before Autodev #79. It is an
  # opt-out a project has to write down, not the default.
  def test_zero_switches_the_check_off_entirely
    fix = fixer(project_config: { 'fix_verification_max' => 0 })

    run_round(fix, discussions(3))

    assert_equal %w[thread-0 thread-1 thread-2], sink[:resolved]
    assert_empty sink[:prompts], 'no verification call is spent when the check is off'
  end
end

# --- 3. the setting --------------------------------------------------------

class MrFixVerificationMaxSettingTest < Minitest::Test
  def fixer(project_config: {}, config: {})
    MrFixer.allocate.tap do |fix|
      fix.instance_variable_set(:@project_config, project_config)
      fix.instance_variable_set(:@config, config)
    end
  end

  def test_prefers_the_project_override_over_the_global
    fix = fixer(project_config: { 'fix_verification_max' => 3 }, config: { 'fix_verification_max' => 7 })

    assert_equal 3, fix.send(:fix_verification_max)
  end

  def test_falls_back_to_the_global_then_the_baked_default
    assert_equal 7, fixer(config: { 'fix_verification_max' => 7 }).send(:fix_verification_max)
    assert_equal MrFixer::DEFAULT_FIX_VERIFICATION_MAX, fixer.send(:fix_verification_max)
  end

  # The default is on. A check that ships switched off fixes nothing, and the
  # bound is what makes leaving it on affordable.
  def test_the_baked_default_leaves_the_check_on
    assert_operator MrFixer::DEFAULT_FIX_VERIFICATION_MAX, :>, 0
  end
end
