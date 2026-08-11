# mr-review diagnostic capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make an `mr-review` failure diagnosable from `production.log` in one
shot (Autodev #49). Today the call keeps stderr and discards stdout, and
`mr-review` fails writing nothing to stderr — 15 production failures, 15 empty log
lines, 3 MRs delivered with no review and no recoverable cause.

**Architecture:** Three bounded changes on the review path. `ProcessRunner#run_with_timeout`
returns the `Process::Status` as an optional fourth element (three-variable
destructuring, which both `danger-claude` callers and every existing test stub
use, is unaffected). `PipelineMonitor::Reviewer#run_mr_review_command` builds a
complete failure diagnostic from it — exit status, both streams, each labelled,
each marked when empty, capped at 2000 characters with an explicit truncation
marker, scrubbed through `Redactor`. `give_up_reviewing` persists `@dc_stdout` /
`@dc_stderr` onto the row so the diagnostic outlives log rotation. The failure
threshold of 5 is **not** changed; the spec argues why and records the aggregate
alert as the follow-up.

**Tech Stack:** Rails 8.1.3, Minitest (`test/**/*_test.rb`), plain Ruby modules
mixed into `PipelineMonitor`.

**Spec:** `docs/superpowers/specs/2026-08-11-mr-review-diagnostic-capture-design.md`

**Predecessor:** `docs/superpowers/specs/2026-08-10-mr-review-timeout-design.md`
(Autodev #54, merged at `83f8c71`) — it rewrote `run_mr_review_command` into its
current shape, and left the discarded stdout untouched.

**Worktree:** `fix/49-mr-review-stdout-diagnostic` (already created, branched from
`master` at `83f8c71`).

## Global Constraints

- **TDD.** Write the failing test, run it, watch it fail for the right reason, then implement.
- **RuboCop must pass**: `mise x ruby -- rubocop <files>` from the worktree root. Never edit any `.rubocop.yml`.
- **Conventional Commits**: `<type>: <description> (Autodev #49)` plus a body explaining the why. End every commit message with `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- **`CHANGELOG.md` `[Unreleased]`** updated in the same pass (Task 4). The section is **not empty** — it carries four bullets under an existing `### Fixed` heading (Autodev #50 ×3, Autodev #54 ×1). Add to that section; do not create a second one.
- **This change adds no user-facing string.** Nothing under `config/locales/` may change. The two new strings go to `production.log` and to `text` columns — neither is a user-facing surface in the sense of the i18n rule.
- **Do not change `REVIEW_FAILURE_THRESHOLD`.** The spec §4 re-examined it and concluded the number should not move without production data. If you think otherwise, say so in your report — do not change it silently.
- **Do not "fix" the `mr-review not installed` → counted-as-failure behaviour** (spec §4, out of scope). Do not try to reproduce the real `mr-review` failure either.
- **Test commands** (run from the worktree root):
  - one file: `mise x ruby -- bundle exec rake test TEST=test/<file>_test.rb`
  - one test: `mise x ruby -- bundle exec rake test TEST=test/<file>_test.rb TESTOPTS="--name=/<pattern>/"`
  - full suite: `mise x ruby -- bundle exec rake test` (baseline on `master`: **1350 runs, 2608 assertions, 0 failures, 0 errors**)

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `lib/autodev/process_runner.rb` | Hands the `Process::Status` back to callers that want it | 1 |
| `test/process_runner_test.rb` | Extended: real subprocess pinning out/err/ok/status and the 3-element compatibility | 1 |
| `lib/autodev/pipeline_monitor/reviewer.rb` | Builds the complete failure diagnostic; persists it on give-up | 2, 3 |
| `test/pipeline_monitor_review_diagnostic_test.rb` | New. Every claim about the failure message | 2 |
| `test/pipeline_monitor_review_failure_test.rb` | Extended: give-up persists the buffers | 3 |
| `CHANGELOG.md` | Docs | 4 |

---

### Task 1: Hand the exit status back from `run_with_timeout`

**Files:**
- Modify: `lib/autodev/process_runner.rb` (`finish_process`, ~line 88)
- Test: `test/process_runner_test.rb` (extend)

**Interfaces:**
- Consumes: nothing new.
- Produces: `run_with_timeout` → `[out, err, ok, status]` where `status` is the
  `Process::Status`. Task 2 reads the fourth element.

**The compatibility property, which the tests must pin:** `out, err, ok = run_with_timeout(...)`
must keep binding exactly as before. Ruby drops surplus elements on destructuring,
so this holds by construction — but it protects both `danger-claude` entry points
(`lib/autodev/danger_claude_runner.rb:54` and `:94`), so it gets an explicit test
rather than an argument.

- [ ] **Step 1: Write the failing tests**

Append to `test/process_runner_test.rb`. The existing `Harness` only carries what
`resolve_timeout` reads; a real spawn needs the two diagnostic buffers as mutable
strings, so give the harness those too (keep the existing `resolve_timeout` tests
working — add optional state, do not rewrite the constructor's signature):

```ruby
  # A real subprocess: the only honest way to pin what run_with_timeout hands
  # back, and it doubles as proof that stdout is captured at all — the premise of
  # Autodev #49, whose whole bug was that the caller threw stdout away.
  def spawn_harness
    harness = Harness.new
    harness.instance_variable_set(:@dc_stdout, +'')
    harness.instance_variable_set(:@dc_stderr, +'')
    harness
  end

  SCRIPT = 'printf hello; printf oops >&2; exit 3'

  def test_a_failed_run_reports_both_streams_and_the_exit_status
    out, err, ok, status = spawn_harness.send(:run_with_timeout, '/bin/sh', ['-c', SCRIPT],
                                              chdir: Dir.pwd, timeout: 30)

    assert_equal 'hello', out
    assert_equal 'oops', err
    refute ok
    assert_equal 3, status.exitstatus
  end

  # The compatibility claim the two danger-claude callers rest on: a surplus
  # fourth element must not disturb a three-variable destructuring.
  def test_a_three_element_destructuring_still_binds
    out, err, ok = spawn_harness.send(:run_with_timeout, '/bin/sh', ['-c', SCRIPT],
                                      chdir: Dir.pwd, timeout: 30)

    assert_equal 'hello', out
    assert_equal 'oops', err
    refute ok
  end
```

Two notes:

- `spawn_process` references `DangerClaudeRunner::CLEAN_ENV`, so the file needs
  `require 'autodev/danger_claude_runner'` alongside its existing
  `require 'autodev/process_runner'`.
- `wait_for_completion` polls with `sleep 1` between checks, so each of these
  tests costs up to a second. Two of them is acceptable; do not add more real
  spawns than these.

- [ ] **Step 2: Run the file and watch it fail for the right reason**

Run: `mise x ruby -- bundle exec rake test TEST=test/process_runner_test.rb`

Expected: `test_a_failed_run_reports_both_streams_and_the_exit_status` fails with
`NoMethodError: undefined method 'exitstatus' for nil` — the fourth element does
not exist yet. `test_a_three_element_destructuring_still_binds` passes already;
that is correct, it is a guard against Task 1 breaking something, not a new
behaviour.

- [ ] **Step 3: Return the status**

In `lib/autodev/process_runner.rb`, `finish_process`:

```ruby
  # The Process::Status is returned as a fourth, optional element (Autodev #49).
  # `status.success?` alone cannot tell "the program ran and refused" (exit 1)
  # from "there was no program to run" (exit 127) from "it was killed before it
  # could say anything" (a termsig) — and on the failure shape this ticket is
  # about, where both streams come back empty, that distinction is the entire
  # diagnostic. Surplus on a three-variable destructuring, so the two
  # danger-claude callers are unaffected.
  def finish_process(status, tag, out_thread, err_thread)
    out, err = record_output(tag, nil, out_thread, err_thread)
    raise Interrupt, "#{tag} interrupted by signal" if status.signaled? && status.termsig == Signal.list['INT']

    [out, err, status.success?, status]
  end
```

- [ ] **Step 4: Run the file again, then the danger-claude neighbours**

```bash
mise x ruby -- bundle exec rake test TEST=test/process_runner_test.rb
mise x ruby -- bundle exec rake test TEST=test/danger_claude_runner_heartbeat_test.rb
mise x ruby -- bundle exec rake test TEST=test/pipeline_monitor_review_heartbeat_test.rb
```

Expected: all pass. The last two are the compatibility check that matters — their
stubs return three-element arrays and their callers destructure three.

- [ ] **Step 5: RuboCop**

Run: `mise x ruby -- rubocop lib/autodev/process_runner.rb test/process_runner_test.rb`

Expected: no offenses.

- [ ] **Step 6: Commit**

```bash
git add lib/autodev/process_runner.rb test/process_runner_test.rb
git commit -F - <<'MSG'
feat: hand the exit status back from run_with_timeout (Autodev #49)

finish_process held a Process::Status and reduced it to a boolean before
returning, so a caller could tell that a command failed but never how. On the
failure this ticket is about — mr-review exiting non-zero with nothing on either
stream — that boolean is the only thing autodev has, and it says nothing: exit
127 (no such program), exit 1 (ran and refused) and a termsig (killed before it
could speak) are three different investigations behind one `false`.

The status is now a fourth, optional element of the returned tuple. Ruby drops
surplus elements on destructuring, so the two danger-claude entry points and
every existing test stub are unaffected — pinned by a test that destructures
three variables from a four-element return, and by a real subprocess test that
checks out, err, ok and exitstatus together. That subprocess test is also the
first direct proof in the suite that stdout is captured at all, which is the
premise the next commit relies on.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
```

---

### Task 2: Report the whole diagnostic when `mr-review` fails

This is the ticket. `run_mr_review_command` currently logs
`"mr-review failed (non-fatal): #{err[0, 300]}"` — stdout discarded, empty stderr
rendered as nothing, truncation silent.

**Files:**
- Modify: `lib/autodev/pipeline_monitor/reviewer.rb` (`run_mr_review_command`, ~line 95)
- Create: `test/pipeline_monitor_review_diagnostic_test.rb`

**Interfaces:**
- Consumes: Task 1's fourth element.
- Produces: nothing later tasks read. `run_mr_review_command` keeps its contract —
  truthy on success, `false` on failure — and `execute_mr_review` keeps returning
  `false` rather than raising, which is what `launch_review` branches on.

**Context for the tests:** copy the `Harness` from
`test/pipeline_monitor_review_heartbeat_test.rb` — it mixes in `DangerClaudeRunner`
+ `PipelineMonitor::Reviewer`, calls `init_runner(client: nil, config: {},
project_config: { 'path' => 'group/project' }, logger: logger, token: 'tok')`,
sets `@dc_issue`, and defines `def sleep(_seconds); end`. `StubLogger`
(`test/stub_logger.rb`) captures every level into `#messages`, so the assertions
read the last captured message. `command_exists?` must be overridden per harness
because `execute_mr_review` otherwise shells out to `which`.

- [ ] **Step 1: Write the failing tests**

Create `test/pipeline_monitor_review_diagnostic_test.rb`:

```ruby
# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/danger_claude_runner'
require 'autodev/pipeline_monitor/reviewer'

# What autodev says when mr-review fails (Autodev #49).
#
# It used to say almost nothing: the call kept stderr and threw stdout away, and
# mr-review fails writing nothing to stderr. Every retained production log tells
# the same story — 15 failures, 15 lines reading exactly
# "mr-review failed (non-fatal): ", no exceptions, ~1s per attempt. Three tickets
# hit REVIEW_FAILURE_THRESHOLD on those failures and were delivered with no
# review at all (#16415/!11343, #16224/!11187, #12852/!11286), and the cause is
# still unknown because the only copy of it was discarded at the call site.
#
# So the failure message must carry: the exit status, both streams, an explicit
# marker for an empty one, a bounded and announced truncation, and no secrets.
class PipelineMonitorReviewDiagnosticTest < Minitest::Test
  include DatabaseTestHelper

  MR_URL = 'https://gitlab.example/mr/1'

  # Host for the mr-review call path only — the full PipelineMonitor pulls in far
  # more than this needs.
  class Harness
    include DangerClaudeRunner
    include PipelineMonitor::Reviewer

    def initialize(issue:, logger:)
      init_runner(client: nil, config: {}, project_config: { 'path' => 'group/project' },
                  logger: logger, token: 'tok')
      @dc_issue = issue
    end

    def sleep(_seconds); end
  end

  def setup
    setup_database
    @issue = create_issue(status: 'reviewing')
    @logger = StubLogger.new
    @harness = Harness.new(issue: @issue, logger: @logger)
    @harness.define_singleton_method(:command_exists?) { |_cmd| true }
  end

  # Drives one failing mr-review run and returns the message that was logged.
  def failure_message(out: '', err: '', status: exited(1))
    @harness.define_singleton_method(:run_with_timeout) { |*| [out, err, false, status] }
    @harness.send(:run_mr_review_command, MR_URL)
    @logger.messages.last
  end

  # Process::Status cannot be constructed directly; a real (trivial) child gives
  # us a genuine one, which is what the production path will hand over.
  def exited(code)
    system("exit #{code}")
    $CHILD_STATUS
  end

  def signalled
    pid = Process.spawn('/bin/sh', '-c', 'kill -9 $$')
    Process.wait(pid)
    $CHILD_STATUS
  end

  # The regression. mr-review writes its error to stdout; autodev threw it away.
  def test_stdout_reaches_the_failure_message
    assert_includes failure_message(out: 'unknown option -H'), 'unknown option -H'
  end

  # The half that already worked must not be traded for the half being added.
  def test_stderr_still_reaches_the_failure_message
    assert_includes failure_message(err: 'boom on stderr'), 'boom on stderr'
  end

  def test_an_empty_stream_is_marked_rather_than_left_blank
    message = failure_message(out: 'only stdout spoke')

    assert_includes message, 'only stdout spoke'
    assert_includes message, 'stderr: (empty)'
  end

  # The shape of all 15 production lines: a message ending in a colon, which
  # reads as a logging bug rather than as a finding. Silence must be asserted.
  def test_two_empty_streams_produce_an_explicit_statement
    message = failure_message

    assert_includes message, 'no output on stdout or stderr'
    refute_match(/:\s*\z/, message, 'the message must not trail off after a colon')
  end

  def test_the_exit_status_is_reported
    assert_includes failure_message(status: exited(127)), 'exit 127'
  end

  def test_a_signalled_process_is_reported_as_such
    assert_includes failure_message(status: signalled), 'signal 9'
  end

  # A stub (or a future caller) returning the old three-element tuple must not
  # crash the diagnostic path — it degrades to saying the status is missing.
  def test_a_missing_status_degrades_instead_of_raising
    @harness.define_singleton_method(:run_with_timeout) { |*| ['out', 'err', false] }
    @harness.send(:run_mr_review_command, MR_URL)

    assert_includes @logger.messages.last, 'exit status unavailable'
  end

  def test_a_long_stream_is_truncated_and_says_how_much_was_dropped
    limit = PipelineMonitor::Reviewer::DIAGNOSTIC_STREAM_LIMIT
    message = failure_message(out: 'x' * (limit + 42))

    assert_includes message, '(42 more characters)'
    assert message.length < limit + 500, 'the whole stream must not reach the log'
  end

  def test_a_stream_at_the_limit_is_not_marked_as_truncated
    limit = PipelineMonitor::Reviewer::DIAGNOSTIC_STREAM_LIMIT

    refute_includes failure_message(out: 'x' * limit), 'more characters'
  end

  # The production logger on this path is Autodev::JobLogger, which — unlike
  # AppLogger — does not scrub. We are printing an external tool's raw output,
  # and mr-review holds the same GitLab PAT autodev does.
  def test_a_gitlab_token_in_the_output_is_scrubbed
    message = failure_message(out: 'auth failed for glpat-AbCdEf123456')

    refute_includes message, 'glpat-AbCdEf123456'
    assert_includes message, '***'
  end

  def test_the_success_path_logs_no_error_and_returns_true
    @harness.define_singleton_method(:run_with_timeout) { |*| ['review body', '', true, exited(0)] }

    assert @harness.send(:run_mr_review_command, MR_URL)
    refute(@logger.messages.any? { |m| m.include?('failed') })
  end
end
```

Notes on this test code:

- `$CHILD_STATUS` is `English`'s alias for `$?`; `require 'English'` is already
  pulled in by the Rails boot in `test_helper.rb`. If it resolves to `nil`, use
  `$?` directly and silence RuboCop's `Style/SpecialGlobalVars` at that line only
  if it complains — do **not** edit `.rubocop.yml`.
- `signalled` spawns a shell that kills itself with SIGKILL, so
  `status.signaled?` is true and `termsig` is 9. If SIGKILL on `$$` behaves
  differently on this platform, assert on `status.termsig` interpolated rather
  than the literal `9`.
- `exited(0)` inside the last test runs in the singleton method's closure — the
  method is defined on the harness, so `exited` is not in scope there. Compute it
  before the `define_singleton_method` and capture it in a local.

- [ ] **Step 2: Run the file and watch it fail for the right reason**

Run: `mise x ruby -- bundle exec rake test TEST=test/pipeline_monitor_review_diagnostic_test.rb`

Expected: FAIL. `NameError: uninitialized constant
PipelineMonitor::Reviewer::DIAGNOSTIC_STREAM_LIMIT` on the two truncation tests,
and the rest failing on a message that contains only the stderr slice — the
stdout, exit-status, `(empty)` and scrubbing assertions all miss. If any test
passes at this point other than `test_the_success_path_logs_no_error_and_returns_true`,
re-read it: it is not asserting what it claims.

- [ ] **Step 3: Build the diagnostic**

In `lib/autodev/pipeline_monitor/reviewer.rb`, add the constant next to
`REVIEW_FAILURE_THRESHOLD`:

```ruby
    # Per stream, in the failure message only. 300 characters (the previous cap,
    # applied to stderr alone) is about four lines — enough to lose the actual
    # error inside a usage dump. Truncation is announced rather than silent, so a
    # log line can ask for a bigger cap instead of hiding the need for one.
    DIAGNOSTIC_STREAM_LIMIT = 2000
```

Then replace the tail of `run_mr_review_command` and add the two builders. Keep
the existing comment block above the method, and append a paragraph recording
#49:

```ruby
    def run_mr_review_command(mr_url)
      log "Running mr-review on #{mr_url}..."
      dc_heartbeat!('mr-review')
      out, err, ok, status = run_with_timeout('mr-review', ['-H', mr_url], chdir: Dir.pwd,
                                                                          timeout: mr_review_timeout)
      return log('Review completed successfully') || true if ok

      log_error "mr-review failed (non-fatal): #{review_failure_diagnostic(out, err, status)}"
      false
    end

    # Everything a reader needs to act on, on one message (Autodev #49). The
    # previous version kept stderr only, and mr-review fails writing nothing
    # there: 15 production failures logged 15 empty lines, and three MRs were
    # delivered unreviewed with the cause discarded at this call site.
    #
    # Scrubbed because the logger on this path in production is
    # Autodev::JobLogger, which does not (AppLogger does), and mr-review holds
    # the same GitLab PAT autodev does.
    def review_failure_diagnostic(out, err, status)
      streams = { 'stdout' => out.to_s.strip, 'stderr' => err.to_s.strip }
      body = if streams.each_value.all?(&:empty?)
               'no output on stdout or stderr'
             else
               streams.map { |name, text| "\n#{name}: #{diagnostic_stream(text)}" }.join
             end
      Redactor.scrub("#{exit_summary(status)}#{body.start_with?("\n") ? '' : ', '}#{body}")
    end

    # An empty stream is stated, not left as a dangling colon — the ambiguity
    # that made the production lines unreadable.
    def diagnostic_stream(text)
      return '(empty)' if text.empty?
      return text if text.length <= DIAGNOSTIC_STREAM_LIMIT

      "#{text[0, DIAGNOSTIC_STREAM_LIMIT]}… (#{text.length - DIAGNOSTIC_STREAM_LIMIT} more characters)"
    end

    # nil when a caller (or a test stub) returns the three-element tuple.
    def exit_summary(status)
      return 'exit status unavailable' if status.nil?
      return "killed by signal #{status.termsig}" if status.signaled?

      "exit #{status.exitstatus}"
    end
```

The `body.start_with?` conditional above is deliberately ugly; **simplify it**.
The intent is only: the status and the body are separated by `", "` when the body
is the one-line "no output" sentence, and by a newline when it is the labelled
streams. Write whichever form reads best and keeps RuboCop quiet (an explicit
`if/else` returning the two assembled strings is likely clearer than the
conditional interpolation).

`Redactor` is already loaded (`lib/autodev/logger.rb` requires it and the module
is global); if the constant does not resolve when you run the test, add
`require_relative '../redactor'` at the top of `reviewer.rb` and say so in your
report.

- [ ] **Step 4: Run the file until green**

Run: `mise x ruby -- bundle exec rake test TEST=test/pipeline_monitor_review_diagnostic_test.rb`

Expected: PASS, 11 runs, 0 failures.

- [ ] **Step 5: Run the two neighbouring review files**

```bash
mise x ruby -- bundle exec rake test TEST=test/pipeline_monitor_review_heartbeat_test.rb
mise x ruby -- bundle exec rake test TEST=test/pipeline_monitor_review_failure_test.rb
```

Expected: PASS. The heartbeat file's stubs return three-element arrays, so it is
the live check that a missing status degrades instead of raising.

- [ ] **Step 6: RuboCop**

Run: `mise x ruby -- rubocop lib/autodev/pipeline_monitor/reviewer.rb test/pipeline_monitor_review_diagnostic_test.rb`

Expected: no offenses. If `Metrics/AbcSize` or `Metrics/MethodLength` trips on
`review_failure_diagnostic`, split the "both empty" branch into its own predicate
rather than shortening the message.

- [ ] **Step 7: Commit**

```bash
git add lib/autodev/pipeline_monitor/reviewer.rb test/pipeline_monitor_review_diagnostic_test.rb
git commit -F - <<'MSG'
fix: report mr-review's whole diagnostic when it fails (Autodev #49)

The failure line kept stderr and threw stdout away. mr-review fails writing
nothing to stderr, so every retained production log says exactly the same thing:
"mr-review failed (non-fatal): " — 15 times, no exceptions, ~1s per attempt once
the 15s pre-sleep is subtracted, so a crash at startup or a rejected argument
rather than a timeout. Three tickets exhausted the five-failure threshold on
those runs and were delivered with no review at all (#16415/!11343,
#16224/!11187, #12852/!11286), and the cause is still unknown today because the
only copy of it was discarded at the call site.

The message now carries the exit status and both streams, each labelled, each
marked "(empty)" rather than rendered as a dangling colon, capped at 2000
characters per stream with the number of dropped characters stated instead of
silently cut at 300. Two empty streams produce a positive sentence — "no output
on stdout or stderr" — because that is the observed case and it must read as a
finding, not as a bug in the logging.

The whole thing goes through Redactor: the logger on this path in production is
Autodev::JobLogger, a SimpleDelegator around Rails' logger that, unlike
AppLogger, does not scrub, and we are now printing an external tool's raw output
from a tool holding the same GitLab PAT autodev does.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
```

---

### Task 3: Keep the diagnostic on the row when the review is given up

**Files:**
- Modify: `lib/autodev/pipeline_monitor/reviewer.rb` (`give_up_reviewing`, ~line 47)
- Test: `test/pipeline_monitor_review_failure_test.rb` (extend)

**Interfaces:**
- Consumes: `@dc_stdout` / `@dc_stderr`, which `ProcessRunner#record_output` has
  been filling for `mr-review` since Autodev #54 routed it through the wrapper.
- Produces: `issues.dc_stdout` / `issues.dc_stderr` populated on the give-up path.

**Why the buffers hold the right thing:** a `PipelineMonitor` is built per job,
and the green branch of `check` performs no `danger-claude` call before the
review, so at give-up time the buffers contain that cycle's `mr-review` run and
nothing else.

- [ ] **Step 1: Write the failing test**

In `test/pipeline_monitor_review_failure_test.rb`, add (the file's `build_monitor`
allocates a bare `PipelineMonitor`, so set the buffers on it explicitly):

```ruby
  # A given-up review is the one terminal, human-facing outcome that recorded
  # nothing about why. production.log rotates; the row does not.
  def test_giving_up_keeps_the_last_mr_review_output_on_the_row
    @issue.update(review_failure_count: PipelineMonitor::Reviewer::REVIEW_FAILURE_THRESHOLD - 1)
    @monitor.instance_variable_set(:@dc_stdout, +"=== mr-review ===\nunknown option -H\n")
    @monitor.instance_variable_set(:@dc_stderr, +"=== mr-review ===\n\n")
    stub_mr_review(success: false)

    @monitor.send(:launch_review, @issue)
    @issue.reload

    assert_includes @issue.dc_stdout, 'unknown option -H'
    assert_equal 'review_failures_exhausted', @issue.attention_reason
  end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `mise x ruby -- bundle exec rake test TEST=test/pipeline_monitor_review_failure_test.rb`

Expected: FAIL on `assert_includes @issue.dc_stdout` with `dc_stdout` still `nil`.

- [ ] **Step 3: Persist the buffers**

In `give_up_reviewing`, extend the existing `update_all`:

```ruby
      # The diagnostic outlives log rotation, in the same columns every other
      # failure in the product uses (Autodev #49). No view renders them for a
      # `done` row yet — surfacing them is a follow-up; losing them is not.
      Issue.where(id: issue.id).update_all(finished_at: Time.current, needs_attention: true,
                                           attention_reason: 'review_failures_exhausted',
                                           dc_stdout: @dc_stdout, dc_stderr: @dc_stderr)
```

- [ ] **Step 4: Run the file**

Run: `mise x ruby -- bundle exec rake test TEST=test/pipeline_monitor_review_failure_test.rb`

Expected: PASS, 7 runs. The six pre-existing tests build the monitor without the
buffers, so they also prove `nil` buffers do not break the `update_all`.

- [ ] **Step 5: RuboCop**

Run: `mise x ruby -- rubocop lib/autodev/pipeline_monitor/reviewer.rb test/pipeline_monitor_review_failure_test.rb`

Expected: no offenses.

- [ ] **Step 6: Commit**

```bash
git add lib/autodev/pipeline_monitor/reviewer.rb test/pipeline_monitor_review_failure_test.rb
git commit -F - <<'MSG'
fix: keep the mr-review diagnostic on the row when the review is given up (Autodev #49)

give_up_reviewing is where a ticket's review is abandoned for good: it flags
needs_attention/review_failures_exhausted, comments on GitLab and hands the MR
back to its author. It recorded nothing about why. The three tickets this ticket
is about carry that flag today, and the only copy of their diagnostic was a log
line that was empty and a log file that rotates.

ProcessRunner#record_output has been folding mr-review's stdout and stderr into
@dc_stdout/@dc_stderr since Autodev #54 routed the call through the wrapper, and
every error handler in the product persists those buffers into
issues.dc_stdout/dc_stderr. The review give-up was the one terminal outcome that
did not, so it now does — two keys on an update_all that already existed.

No view renders those columns for a `done` row today; the CLI's --errors display
reads them only for status: error. This makes the diagnostic durable and attached
to the ticket rather than visible, which is the part that cannot be recovered
later. Surfacing it is recorded as a follow-up.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
```

---

### Task 4: Changelog

**Files:**
- Modify: `CHANGELOG.md` (`[Unreleased]`, into the existing `### Fixed` section)

- [ ] **Step 1: Add the entry**

Append one bullet after the Autodev #54 bullet, in the register the surrounding
entries use (the incident, the evidence, the change, the boundary). It must state:
the 15 empty log lines and what they cost (three MRs delivered unreviewed, cause
still unknown); that stdout was discarded and stderr was empty; the new message
shape (exit status, both streams, `(empty)` markers, 2000-character cap with the
dropped count, `Redactor`); the fourth tuple element and why three-variable
destructuring is unaffected; the give-up path persisting the buffers, with the
"not rendered for a `done` row yet" caveat; and that **`REVIEW_FAILURE_THRESHOLD`
is deliberately unchanged**, with the reason (all 15 attempts failed
deterministically from the first, so no threshold value would have saved those
MRs) and the follow-up it points at (an aggregate signal for a globally broken
`mr-review`). Reference the design spec by path.

- [ ] **Step 2: Full suite**

Run: `mise x ruby -- bundle exec rake test`

Expected: 0 failures, 0 errors. Baseline on `master` is 1350 runs / 2608
assertions; this branch adds 14 tests. Quote the real counts in your report.

- [ ] **Step 3: RuboCop over the whole project**

Run: `mise x ruby -- rubocop`

Expected: the offense count must match `master`'s — **46 offenses across 9 files**,
all Rails-generated boilerplate (`bin/*`, `config/initializers/*`, `db/seeds.rb`,
`app/helpers/application_helper.rb`, `app/models/application_record.rb`),
pre-existing and untouched by this branch. A different count means one of your
files introduced an offense: fix the file, never `.rubocop.yml`.

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md
git commit -F - <<'MSG'
docs: record the mr-review diagnostic capture (Autodev #49)

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
```

---

## Verification

Before reporting the work done, confirm all three:

1. `mise x ruby -- bundle exec rake test` — 0 failures, 0 errors. Quote the counts.
2. `mise x ruby -- rubocop` — 46 offenses, the same 9 pre-existing boilerplate files as `master`.
3. `git log --oneline master..HEAD` — five commits (the spec + plan, then Tasks 1–4).

Then hand back for review. Nothing is pushed and no MR is opened; the repo's
convention is a merge commit per `fix/*` branch, done by a human, and Skynet #49
gets its progress note from the same human.

## Open questions for the human reviewer

- **The `autodev` label on `powerpanne/core`.** `labels_todo` is
  `["To do", "Development::ToDo"]`, so the label triggers nothing — an interface
  trap, not a defect. Drop it from the project or add it to `labels_todo`: an
  arbitration to make with the requester, deliberately not decided here.
- **The aggregate alert** for a globally broken `mr-review` (spec §4). Worth its
  own ticket; its threshold and window should be chosen against production
  numbers.
- **Whether a `done + needs_attention` row should render `dc_stdout` /
  `dc_stderr`** in the web UI (spec §3).
