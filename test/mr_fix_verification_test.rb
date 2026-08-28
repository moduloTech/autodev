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
  # writes nothing, i.e. the pass ran and produced no contract). `git` is how the
  # work directory behaves: `:ok`, or one of the two ways `git` can decline to
  # answer at all — which is a different thing from answering "nothing changed",
  # see section 1b.
  def fixer(project_config: {}, answer: nil, diff: DIFF, raises: nil, git: :ok)
    MrFixer.allocate.tap do |fix|
      configure(fix, project_config)
      silence(fix)
      stub_fix_steps(fix, diff, git)
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

  def configure(fix, project_config)
    fix.instance_variable_set(:@project_config, project_config)
    fix.instance_variable_set(:@config, {})
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
  def stub_fix_steps(fix, diff, git)
    bucket = sink
    fix.define_singleton_method(:format_discussion) { |d, **| "thread body of #{d[:id]}" }
    fix.define_singleton_method(:run_fix_prompt) { |*| nil }
    fix.define_singleton_method(:danger_claude_commit) { |*| nil }
    fix.define_singleton_method(:resolve_discussion) { |_mr_iid, id| bucket[:resolved] << id }
    stub_git(fix, diff, git)
  end

  # A failing `git` reports the same way the real one does: a non-zero status and
  # an empty stdout — which is exactly why an empty stdout on its own cannot be
  # read as "the correction changed nothing".
  def stub_git(fix, diff, git)
    fix.define_singleton_method(:run_cmd_status) do |cmd, **|
      head = cmd.include?('rev-parse')
      next ['', 'fatal: not a git repository', false] if head && git == :head_fails
      next ['sha-before', '', true] if head
      next ['', 'fatal: bad object sha-before', false] if git == :diff_fails

      [diff, '', true]
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

    assert_empty sink[:prompts], 'an empty diff is answered without spending a verification call'
    assert_includes sink[:activity].map(&:first), :discussion_unchanged
    refute_includes sink[:activity].map(&:first), :discussion_unverifiable
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

# --- 1b. a measurement that did not happen is not a measurement ------------

# Autodev #79, round 2. The comment above `verify_fix` states the doctrine — the
# neutral value here is `addressed`, so a check that could not be performed must
# not produce it — and one path went round it, one level below where the doctrine
# was written.
#
# `correction_diff` answered `nil` for two opposite things: "the correction
# changed nothing", which is a **measured fact**, and "git did not answer", which
# is a **measurement that did not happen**. `verify_fix` collapsed both into
# `:unchanged`. The report was not merely imprecise, it was the wrong sentence:
# "no change produced" sends a reader to danger-claude, and the fault is in git
# or in the work directory.
#
# And it does not stop at the wording. Every thread of the round takes that same
# path, so nothing is resolved, the round pushes with zero resolutions, the next
# round finds the identical set of threads, `discussion_stagnated?` recognises
# the signature, and `stagnation_threshold` rounds later the request is abandoned
# — `label_attention`, ticket handed back to its author, a public comment. A
# failure to measure produced a give-up.
#
# `:unverifiable` is the case the `cause` enumeration exists for, and this is
# what it is for. The distinction is made in `correction_diff`, which no longer
# has `nil` in its vocabulary at all: an empty String is the fact, a `GitError`
# is the absence of one. Same shape as `GitlabHelpers.answer` (Autodev #62) —
# a failed read raises instead of returning something a caller can misread.
class MrFixVerificationDegradedGitTest < Minitest::Test
  include FixVerificationHarness

  def teardown
    FileUtils.rm_rf(@tmp_dir) if @tmp_dir
  end

  def test_a_git_diff_that_failed_is_not_reported_as_an_empty_diff
    fix = fixer(git: :diff_fails)

    run_round(fix, discussions(1))

    keys = sink[:activity].map(&:first)

    assert_includes keys, :discussion_unverifiable
    refute_includes keys, :discussion_unchanged, 'git declining to answer is not "the fix changed nothing"'
  end

  # `head_sha` runs before the fix rather than after it, so it fails for its own
  # reasons — but the answer is the same one: this correction cannot be measured.
  # Same cause, so the same sentence and the same open thread; only the detail
  # differs, and the detail is what a reader needs.
  def test_an_unreadable_head_is_not_reported_as_an_empty_diff
    fix = fixer(git: :head_fails)

    run_round(fix, discussions(1))

    keys = sink[:activity].map(&:first)

    assert_includes keys, :discussion_unverifiable
    refute_includes keys, :discussion_unchanged
  end

  # The thread stays open either way — that half was never broken, and it must
  # stay true now that the classification changed.
  def test_a_correction_that_could_not_be_measured_never_resolves_its_thread
    fix = fixer(git: :diff_fails)

    run_round(fix, discussions(1))

    assert_empty sink[:resolved]
  end

  # Nothing is spent asking Claude about a diff nobody could read.
  def test_a_git_failure_spends_no_verification_call
    fix = fixer(git: :diff_fails)

    run_round(fix, discussions(1))

    assert_empty sink[:prompts]
  end

  # The entry has to point at git. Naming the class is what separates "look at
  # the work directory" from "look at what danger-claude wrote".
  def test_the_entry_names_the_failure_that_actually_happened
    fix = fixer(git: :diff_fails)
    run_round(fix, discussions(1))

    _key, vars = sink[:activity].find { |key, _| key == :discussion_unverifiable }

    assert_match(/GitError/, vars[:error])
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

# --- 4. what a round that resolved nothing says ----------------------------

# Autodev #79, round 2. `announce_fix_success` withheld the GitLab comment when
# the round resolved nothing, with the reason written next to it: a public
# "0 discussion(s) corrigee(s)" announces a delivery that did not happen. Three
# lines below, `log_activity(:discussions_fixed, count: 0)` was called with no
# condition at all — and `ActivityLogger.post` writes that entry **into the
# activity note on the GitLab issue**. The guarded sentence was posted anyway, by
# the other sink. Two guards were needed and only one was written, which is the
# argument for having one decision instead of two.
#
# Silence is not the answer either: "this round could not resolve anything" is
# worth reading, and it is the line that makes the run of identical rounds before
# a `stagnation_discussions` give-up legible. It gets its own key, so it cannot
# be mistaken for a success by a reader or by a counter.
class MrFixRoundReportTest < Minitest::Test
  FakeIssue = Struct.new(:issue_iid, :mr_iid, :mr_url) do
    # The AASM event is not what this section is about; it must simply still fire.
    def discussions_fixed! = nil
  end

  def setup
    @sink = { activity: [], notify: [] }
  end

  def reporter
    bucket = @sink
    MrFixer.allocate.tap do |fix|
      fix.define_singleton_method(:log) { |*| nil }
      fix.define_singleton_method(:log_activity) { |_issue, key, **vars| bucket[:activity] << [key, vars] }
      fix.define_singleton_method(:notify_localized) { |_iid, key, **vars| bucket[:notify] << [key, vars] }
    end
  end

  def issue = FakeIssue.new(11, 42, 'http://gitlab/mr/42')

  def report(count) = reporter.send(:complete_discussion_fix, issue, count, 3)

  def test_a_round_that_resolved_nothing_writes_no_success_line
    report(0)

    refute_includes @sink[:activity].map(&:first), :discussions_fixed,
                    'the activity note is posted on the GitLab issue too'
  end

  def test_a_round_that_resolved_nothing_posts_no_success_comment
    report(0)

    assert_empty @sink[:notify]
  end

  def test_a_round_that_resolved_nothing_still_says_so
    report(0)

    _key, vars = @sink[:activity].find { |key, _| key == :discussions_none_resolved }

    assert_equal 3, vars[:round]
  end

  # Control: a round that did resolve something reports it on both sinks, exactly
  # as before.
  def test_a_round_that_resolved_something_reports_it
    report(2)

    assert_includes @sink[:activity].map(&:first), :discussions_fixed
    assert_equal %i[mr_fix_success], @sink[:notify].map(&:first)
  end

  # The handover to the pipeline watch is a property of the round ending, not of
  # what it achieved.
  def test_the_pipeline_watch_line_is_written_either_way
    report(0)

    assert_includes @sink[:activity].map(&:first), :pipeline_watch
  end
end
