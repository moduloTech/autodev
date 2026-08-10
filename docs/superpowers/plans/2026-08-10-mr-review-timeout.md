# mr-review timeout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cap `mr-review` with a timeout so `reviewing` — a state the dormant audit repositions rows out of — can no longer stay silent forever under a live worker (Autodev #54).

**Architecture:** Route the `mr-review` shell-out through `ProcessRunner#run_with_timeout` instead of a raw `Open3.capture3`, so `reviewing` leaves the exceptions list the previous ticket put it on. Tasks 1–3 capped it at `dc_timeout`, which needed no `HealthReport` change; the final review then measured production review durations and reversed that — the Addendum's Tasks 4–5 replace the cap with a per-project `mr_review_timeout` (baked default 3600) and add one term to `longest_worker_timeout`, window-neutral at the default since `2 × 3600` is the existing 7200 floor. The non-fatal-on-timeout behaviour needs no new code (`run_with_timeout` raises, `execute_mr_review`'s existing `rescue` returns `false`, `launch_review` increments `review_failure_count` from there); it needs a test. The dead review path in `IssueProcessor::MrManager` is deleted rather than kept in sync.

**Tech Stack:** Rails 8.1.3, Minitest (`test/**/*_test.rb`), plain Ruby modules mixed into `PipelineMonitor` / `IssueProcessor`.

**Spec:** `docs/superpowers/specs/2026-08-10-mr-review-timeout-design.md`

**Predecessor:** `docs/superpowers/specs/2026-08-10-live-worker-silence-invariant-design.md` (Autodev #50, merged as `8249d2a`) — it added the `dc_heartbeat!('mr-review')` call this plan keeps, and recorded `reviewing` as the exception this plan closes.

**Worktree:** `fix/54-mr-review-timeout` (already created, branched from `master` at `8249d2a`, spec committed as `73dea23`).

## Global Constraints

- **TDD.** Write the failing test, run it, watch it fail for the right reason, then implement.
- **RuboCop must pass**: `mise x ruby -- rubocop <files>` from the worktree root. Never edit any `.rubocop.yml`.
- **Conventional Commits**: `<type>: <description>` (`feat`, `fix`, `refactor`, `test`, `docs`, `chore`) plus a body explaining the why. End every commit message with `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- **`CHANGELOG.md` `[Unreleased]`** is updated in the same pass (Task 3). Note `[Unreleased]` is **not empty** — it already carries three bullets from Autodev #50 under a `### Fixed` heading. Add to that section; do not create a second one.
- **This change adds no user-facing string.** Nothing under `config/locales/` should change. If you find yourself writing a literal a user could read, stop — it must go through `Locales.t` / `t_web` in **both** `fr` and `en`.
- **Language per document.** `CHANGELOG.md` is English. `docs/observability.md` and `docs/usage/autodev-technical-usage.md` are **French** — do not switch either, and write native technical French.
- **`docs/observability.md` renders through Redcarpet** in the dashboard: never nest a single-backtick code span inside another one. Each identifier gets its own span. (This broke once on the predecessor ticket.)
- **Test commands** (run from the worktree root):
  - one file: `mise x ruby -- bundle exec rake test TEST=test/<file>_test.rb`
  - one test: `mise x ruby -- bundle exec rake test TEST=test/<file>_test.rb TESTOPTS="--name=/<pattern>/"`
  - full suite: `mise x ruby -- bundle exec rake test`
- **Tasks 1–3 only: do not touch `app/services/autodev/health_report.rb`, and do not give `mr-review` its own configurable timeout.** Those two constraints held while the cap was `dc_timeout`. The final review measured production review durations and reversed that decision — **Tasks 4 and 5 (see the Addendum) require both**: a per-project `mr_review_timeout` and one added term in `longest_worker_timeout`. If you are implementing Task 4 or 5, the Addendum governs and this line does not bind you.
- **Do not move `dc_heartbeat!` into `run_with_timeout`.** It would cover all three callers from one place, and it was considered and rejected in the spec: the tests that pin the heartbeat work by stubbing `run_with_timeout`, so the pin would become circular and would have to reach down to `spawn_process` with fake pipes and a pid `Process.wait2` accepts.
- **Do not add `http.lowSpeedLimit` (or any other bound) to the untimed git operations.** The predecessor's final review inventoried them — `clone`, `push`, rebase, the `clone_and_checkout` inside `running_post_completion`, screenshot uploads — and none is a real risk today (`clone_depth` defaults to 1, so the failure mode is a wedged TCP connection, not a large repo). It is a separate change with its own failure modes, recorded on the ticket.

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `lib/autodev/pipeline_monitor/reviewer.rb` | The one live review path: runs `mr-review` under a timeout, non-fatally | 1 |
| `test/pipeline_monitor_review_heartbeat_test.rb` | Extended. The review path's contract: timeout wrapper used, timeout non-fatal, heartbeat still written | 1 |
| `lib/autodev/issue_processor/mr_manager.rb` | Loses its dead review trio; keeps MR creation only | 2 |
| `CHANGELOG.md`, `docs/observability.md`, `docs/usage/autodev-technical-usage.md`, `docs/superpowers/specs/2026-08-10-live-worker-silence-invariant-design.md` | Docs | 3 |

---

### Task 1: Run `mr-review` under a timeout

**Files:**
- Modify: `lib/autodev/pipeline_monitor/reviewer.rb:80-91` (`run_mr_review_command`)
- Test: `test/pipeline_monitor_review_heartbeat_test.rb` (extend; two existing tests need adapting)

**Interfaces:**
- Consumes: `ProcessRunner#run_with_timeout(cmd, args, chdir:, label: nil)` → `[out, err, ok]`, raising `ImplementationError` on timeout (already exists, `lib/autodev/process_runner.rb:11`). `DangerClaudeRunner#dc_heartbeat!(label)` (already exists).
- Produces: nothing later tasks consume. `run_mr_review_command(mr_url)` keeps its contract — returns truthy on success, `false` on failure — and `execute_mr_review(issue)` keeps returning `false` rather than raising, which is what `launch_review` branches on.

**Context you need for the tests:** the existing test file's `Harness` mixes in `DangerClaudeRunner` + `PipelineMonitor::Reviewer`, calls `init_runner` with `client: nil`, and defines `def sleep(_seconds); end` so the 15 s wait is instant. Its two existing tests stub `Open3.capture3` — that call is leaving the path, so they must move to stubbing `run_with_timeout`. Both also override `command_exists?` per-test, because `execute_mr_review` probes for the binary with a real `Open3.capture2e('which', …)`.

**One inherited side effect, already adjudicated — do not "fix" it.** `run_with_timeout` calls `PortAllocator.release(@port_mappings) if @port_mappings`, which is a danger-claude concern (freeing host ports so Docker can bind them) that a non-danger-claude command now inherits. It cannot bite: `@port_mappings` is only ever set by `dc_global_args`, no danger-claude call precedes the review inside one `PipelineMonitor#check` (the pipeline evaluator runs on the red branch, the review on the green one), and `PortAllocator.release` swallows per-socket errors so even a stale mapping is a no-op. Leave it alone; the reasoning is in the spec §1 so a reviewer can check it rather than rediscover it.

- [ ] **Step 1: Write the failing tests**

Replace the whole body of `test/pipeline_monitor_review_heartbeat_test.rb` below the `Harness` class (keep `Harness` as it is, and keep the `setup` / `heartbeats` helpers) with the following, and update the file's leading comment as shown:

```ruby
# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'
require 'autodev/danger_claude_runner'
require 'autodev/pipeline_monitor/reviewer'

# The `reviewing` state's silence contract (Autodev #50, then #54).
#
# mr-review is an LLM review of a full MR diff. It used to run via a raw
# Open3.capture3 with no timeout, which made `reviewing` — a state
# dispatch_dormant_audit repositions rows out of — able to stay silent forever
# under a live worker. #50 added a heartbeat immediately before the call, bounding
# that silence at one mr-review run; #54 routes the call through
# ProcessRunner#run_with_timeout, so "one run" is now a bounded number of seconds
# (dc_timeout), which HealthReport#longest_worker_timeout already accounts for.
#
# The timeout must stay NON-FATAL: run_with_timeout raises, execute_mr_review's
# rescue turns that into `false`, and launch_review counts it as a review failure
# (review_failure_count, threshold 5) rather than dropping the request to `error`.
class PipelineMonitorReviewHeartbeatTest < Minitest::Test
  include DatabaseTestHelper

  # Host for PipelineMonitor::Reviewer's mr-review call path. Only
  # DangerClaudeRunner + Reviewer are mixed in — the full PipelineMonitor class
  # pulls in far more than this call path needs.
  class Harness
    include DangerClaudeRunner
    include PipelineMonitor::Reviewer

    def initialize(issue:, logger:)
      init_runner(client: nil, config: {}, project_config: { 'path' => 'group/project' },
                  logger: logger, token: 'tok')
      @dc_issue = issue
    end

    # Kernel#sleep stand-in so the test doesn't actually wait 15s.
    def sleep(_seconds); end
  end

  def setup
    setup_database
    @issue = create_issue(status: 'reviewing')
    @harness = Harness.new(issue: @issue, logger: StubLogger.new)
    @harness.define_singleton_method(:command_exists?) { |_cmd| true }
  end

  def heartbeats
    ActivityEvent.where(issue_id: @issue.id, kind: 'heartbeat').order(:id).to_a
  end

  # Records what reached the timeout wrapper and returns the triple it produces.
  def stub_timeout_wrapper(result)
    calls = []
    @harness.define_singleton_method(:run_with_timeout) do |cmd, args, **opts|
      calls << { cmd: cmd, args: args, opts: opts }
      result
    end
    calls
  end

  # The point of the ticket: the call is wrapped, not raw. Without this
  # assertion a revert to Open3.capture3 would leave every other test green.
  def test_mr_review_runs_through_the_timeout_wrapper
    calls = stub_timeout_wrapper(['', '', true])
    Open3.stub :capture3, ->(*) { raise 'Open3.capture3 must not be on the mr-review path' } do
      @harness.send(:run_mr_review_command, 'https://gitlab.example/mr/1')
    end

    assert_equal 1, calls.size
    assert_equal 'mr-review', calls.first[:cmd]
    assert_equal ['-H', 'https://gitlab.example/mr/1'], calls.first[:args]
  end

  # chdir is required by run_with_timeout and was implicit with Open3.capture3.
  # mr-review works through the GitLab API, so the process's own cwd is correct —
  # pinned so nobody "tidies" it into a work_dir that may not exist.
  def test_the_wrapper_is_called_with_the_current_working_directory
    calls = stub_timeout_wrapper(['', '', true])
    @harness.send(:run_mr_review_command, 'https://gitlab.example/mr/1')

    assert_equal Dir.pwd, calls.first[:opts][:chdir]
  end

  def test_the_success_path_returns_true
    stub_timeout_wrapper(['', '', true])

    assert @harness.send(:run_mr_review_command, 'https://gitlab.example/mr/1')
  end

  def test_the_failure_path_returns_false
    stub_timeout_wrapper(['', 'boom', false])

    refute @harness.send(:run_mr_review_command, 'https://gitlab.example/mr/1')
  end

  # The non-fatal contract. run_with_timeout raises ImplementationError on
  # timeout; execute_mr_review's rescue must absorb it and answer `false`, which
  # is what launch_review reads to increment review_failure_count instead of
  # failing the request.
  def test_a_timeout_is_absorbed_and_answers_false
    @harness.define_singleton_method(:run_with_timeout) do |*|
      raise ImplementationError, 'mr-review timed out after 1800s'
    end

    result = nil
    assert_nothing_raised { result = @harness.send(:execute_mr_review, @issue) }
    refute result
  end

  # The heartbeat is written before the call, so a killed run still leaves proof
  # the worker was alive up to that moment — which is what keeps the dormant
  # audit off the row.
  def test_a_timeout_still_leaves_exactly_one_heartbeat
    @harness.define_singleton_method(:run_with_timeout) do |*|
      raise ImplementationError, 'mr-review timed out after 1800s'
    end
    @harness.send(:execute_mr_review, @issue)

    assert_equal 1, heartbeats.size
    assert_equal 'mr-review', heartbeats.first.payload['label']
  end

  def test_execute_mr_review_writes_one_heartbeat
    stub_timeout_wrapper(['', '', true])
    @harness.send(:execute_mr_review, @issue)

    assert_equal 1, heartbeats.size
    assert_equal 'mr-review', heartbeats.first.payload['label']
  end

  def test_heartbeat_is_written_even_when_mr_review_fails
    stub_timeout_wrapper(['', 'boom', false])
    @harness.send(:execute_mr_review, @issue)

    assert_equal 1, heartbeats.size
  end
end
```

Two notes on this test code:

- `assert_nothing_raised` is not part of Minitest — it comes from `ActiveSupport::Testing::Assertions`, which `Minitest::Test` does **not** include. If it raises `NoMethodError` when you run the file, replace that test's body with the plain-Ruby equivalent, which asserts the same thing:

  ```ruby
    result = @harness.send(:execute_mr_review, @issue)

    refute result, 'a timeout must be absorbed into false, not raised'
  ```

  (an escaping exception fails the test by erroring it, which is the outcome we want to catch either way). Note in your report which form you used and why.
- `ImplementationError` is defined in `autodev/errors`, which `test_helper.rb` already requires — no new `require` is needed.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mise x ruby -- bundle exec rake test TEST=test/pipeline_monitor_review_heartbeat_test.rb`

Expected: FAIL. `test_mr_review_runs_through_the_timeout_wrapper` fails on `Open3.capture3 must not be on the mr-review path` (the raw call is still there), and the two `chdir` / wrapper-argument tests get `0` recorded calls. The two timeout tests may already pass — `run_with_timeout` is stubbed to raise and the existing `rescue` catches it — which is expected and is the point of §2 of the spec: that behaviour already holds and is only now pinned.

- [ ] **Step 3: Route the call through the timeout wrapper**

In `lib/autodev/pipeline_monitor/reviewer.rb`, replace `run_mr_review_command`:

```ruby
    # mr-review is not a danger-claude call, so it gets no heartbeat of its own
    # from DangerClaudeRunner — hence the explicit marker (Autodev #50), written
    # before the call so the clock starts as late as possible.
    #
    # It runs under run_with_timeout rather than a raw Open3 (Autodev #54): the
    # cap is `dc_timeout`, which HealthReport#longest_worker_timeout already
    # folds into the stuck-window, so `reviewing` stops being an exception the
    # window cannot size. On timeout the wrapper raises ImplementationError,
    # which execute_mr_review's rescue turns into `false` — a review failure
    # counted by launch_review, not a failed request.
    #
    # chdir: Dir.pwd keeps the previous behaviour. Open3.capture3 inherited the
    # process's cwd, and mr-review works through the GitLab API rather than in a
    # local clone, so it has no repo to sit in.
    def run_mr_review_command(mr_url)
      log "Running mr-review on #{mr_url}..."
      dc_heartbeat!('mr-review')
      _, err, ok = run_with_timeout('mr-review', ['-H', mr_url], chdir: Dir.pwd, label: 'mr-review')
      return log('Review completed successfully') || true if ok

      log_error "mr-review failed (non-fatal): #{err[0, 300]}"
      false
    end
```

Leave `command_exists?` alone — it still uses `Open3.capture2e`, so the file's `Open3` dependency stays.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mise x ruby -- bundle exec rake test TEST=test/pipeline_monitor_review_heartbeat_test.rb`

Expected: PASS, 8 runs, 0 failures.

- [ ] **Step 5: Check the neighbouring review test still passes**

Run: `mise x ruby -- bundle exec rake test TEST=test/pipeline_monitor_review_failure_test.rb`

Expected: PASS. That file covers `finalize_review_failure` / `review_failure_count` / `REVIEW_FAILURE_THRESHOLD` — the exact path a timeout now travels — so it is the one most likely to notice if the return contract changed.

- [ ] **Step 6: RuboCop**

Run: `mise x ruby -- rubocop lib/autodev/pipeline_monitor/reviewer.rb test/pipeline_monitor_review_heartbeat_test.rb`

Expected: no offenses. If `Metrics/MethodLength` trips on `run_mr_review_command`, the comment block is above the method (not inside it) so it does not count — check you did not accidentally place it inside the method body.

- [ ] **Step 7: Commit**

```bash
git add lib/autodev/pipeline_monitor/reviewer.rb test/pipeline_monitor_review_heartbeat_test.rb
git commit -F - <<'MSG'
fix: run mr-review under a timeout (Autodev #54)

mr-review ran via a raw Open3.capture3 with no timeout, in the `reviewing` state
— which is in Issue::STALLED_STATES, so dispatch_dormant_audit repositions rows
out of it by update_all, outside the per-issue concurrency lock. Autodev #50
added a heartbeat before the call, bounding that silence at one mr-review run
instead of leaving it unbounded, but a run that never returns was still
unbounded and no configured value sized the window for it.

It now runs under ProcessRunner#run_with_timeout, capped at dc_timeout. That term
is already in HealthReport#longest_worker_timeout, so the derived stuck-window
covers `reviewing` with no change to HealthReport — the state stops being an
exception the arithmetic cannot reach.

The non-fatal contract needed no new code and now has tests: the wrapper raises
ImplementationError, execute_mr_review's existing rescue answers false, and
launch_review counts a review failure (threshold 5) rather than failing the
request. The tests also pin that the call is wrapped at all — a revert to
Open3.capture3 would otherwise leave them green — and that chdir stays the
process's own cwd, which Open3.capture3 inherited implicitly.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
```

---

### Task 2: Delete the dead review path in `MrManager`

`IssueProcessor::MrManager#run_review` has no caller anywhere in `app/`, `lib/`, `test/` or `bin/`. `#execute_review` is called only by it, and `#command_exists?` only by those two. The trio duplicates `Reviewer`'s logic — same binary probe, same 15 s sleep, same shell-out — and has already drifted: Autodev #50 added a heartbeat there for a call that never executes.

**Files:**
- Modify: `lib/autodev/issue_processor/mr_manager.rb:32-59` (remove `run_review`, `execute_review`, `command_exists?`)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing. `MrManager` keeps `create_merge_request` and `find_existing_mr`, which are live.

- [ ] **Step 1: Confirm the trio is dead before deleting anything**

Run:

```bash
grep -rn "run_review\|execute_review\|command_exists?" --include="*.rb" app lib test bin | grep -v "def run_review\|def execute_review\|def command_exists?"
```

Expected: the only hits are `mr_manager.rb`'s internal `execute_review(mr_url)` call inside `run_review`, plus `reviewer.rb`'s own `command_exists?('mr-review')` call and the test overrides in `test/pipeline_monitor_review_heartbeat_test.rb`. **No hit may call `run_review`.**

If any hit shows a live caller, STOP: do not delete, and report it. The deletion's whole justification is that nothing calls it.

- [ ] **Step 2: Delete the three methods**

In `lib/autodev/issue_processor/mr_manager.rb`, remove `run_review`, `execute_review` and `command_exists?` entirely — the block from `def run_review(mr_url)` through the `end` of `command_exists?`. The module keeps `create_merge_request` and `find_existing_mr`, and its class comment must lose the review half:

```ruby
class IssueProcessor
  # Merge request creation and lookup. Reviews are PipelineMonitor::Reviewer's
  # job — this module used to carry a parallel, never-called copy of that path
  # (removed in Autodev #54).
  module MrManager
```

Check whether `Open3` is still referenced in the file after the deletion. If it is not, and the file has a `require 'open3'` of its own, remove it; if the require lives elsewhere (it is loaded globally by `danger_claude_runner.rb`'s dependencies), change nothing. Report which case applied.

- [ ] **Step 3: Run the issue-processor tests**

Run:

```bash
mise x ruby -- bundle exec rake test TEST=test/issue_processor_create_mr_test.rb
```

Expected: PASS. This is the file that covers what `MrManager` still does.

- [ ] **Step 4: Run the full suite**

Run: `mise x ruby -- bundle exec rake test`

Expected: 0 failures, 0 errors. For a deletion this is the load-bearing check — a green suite is what proves nothing referenced the removed methods. Quote the counts in your report. If anything fails, do not re-add the methods to make it pass without first reporting what referenced them.

- [ ] **Step 5: RuboCop**

Run: `mise x ruby -- rubocop lib/autodev/issue_processor/mr_manager.rb`

Expected: no offenses.

- [ ] **Step 6: Commit**

```bash
git add lib/autodev/issue_processor/mr_manager.rb
git commit -F - <<'MSG'
refactor: delete the dead review path in MrManager (Autodev #54)

run_review had no caller anywhere in app/, lib/, test/ or bin/; execute_review
was called only by it and command_exists? only by those two. The trio duplicated
PipelineMonitor::Reviewer — same binary probe, same 15s sleep, same shell-out —
and had started to drift: Autodev #50 added a heartbeat there for a call that
never executes, and #54 would otherwise have had to add a timeout to it for the
same non-reason.

Reviewer is now the only review path, which it already was in practice. MrManager
keeps MR creation and lookup.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
```

---

### Task 3: Docs — `reviewing` leaves the exceptions list

**Files:**
- Modify: `CHANGELOG.md` (`[Unreleased]`, into the existing `### Fixed` section)
- Modify: `docs/observability.md:48` (remove the bullet)
- Modify: `docs/usage/autodev-technical-usage.md:177` (the `dc_timeout` row)
- Modify: `docs/superpowers/specs/2026-08-10-live-worker-silence-invariant-design.md:217-228` (rewrite the exception paragraph)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Add the changelog entry**

In `CHANGELOG.md`, under `## [Unreleased]`'s existing `### Fixed` heading, after the three Autodev #50 bullets, add:

```markdown
- **A review that never returns can no longer leave a ticket exposed (Autodev #54).** `mr-review` ran via a raw `Open3.capture3` with **no timeout**, in the `reviewing` state — which is in `Issue::STALLED_STATES`, so `dispatch_dormant_audit` repositions rows out of it with `update_all`, outside the per-issue concurrency lock. #50 bounded that silence at one `mr-review` run by writing a heartbeat before the call, but a wedged run (process hung, pipe never closed) was still unbounded, and no configured value sized the stuck-window for it — `reviewing` was recorded as the one exception the derived window could not reach. It now runs under `ProcessRunner#run_with_timeout`, capped by `dc_timeout` (30 min by default, raisable per project). Because `dc_timeout` is already a term of `HealthReport#longest_worker_timeout`, the derived window covers `reviewing` with no change to `HealthReport`, and the state leaves the exceptions list — `running_post_completion` is now the only one, and the arithmetic covers it. A timeout stays **non-fatal**, as before: the wrapper raises, `Reviewer#execute_mr_review`'s existing rescue answers `false`, and `launch_review` counts a review failure (`review_failure_count`, threshold 5) rather than dropping the request to `error` — behaviour that already held and is now pinned by tests, alongside assertions that the call is wrapped at all and that its working directory stays the process's own cwd (which `Open3.capture3` inherited implicitly). Relatedly, `IssueProcessor::MrManager`'s parallel review path — `run_review` / `execute_review` / `command_exists?`, ~25 lines with no caller anywhere, duplicating `Reviewer` — was deleted rather than kept in sync; `PipelineMonitor::Reviewer` is now the only review path, which it already was in practice.
```

- [ ] **Step 2: Remove the exception bullet from `docs/observability.md`**

Delete the entire bullet at line 48, which begins:

```
- **Exception reconnue : `reviewing`.** `mr-review` tourne dans cet état via un `Open3.capture3` sans timeout
```

It is one line (a single long bullet). The `stuck_issues` bullet above it (line 47) and the "Toute exception dans un check" bullet below it stay untouched: line 47 already describes the window generically (`2 × le plus long timeout configuré`, `pris sur dc_timeout et post_completion_timeout`), which remains accurate now that `mr-review` is capped by `dc_timeout`.

- [ ] **Step 3: Update the `dc_timeout` row in the technical guide**

In `docs/usage/autodev-technical-usage.md`, line 177 currently reads:

```
| Exécution | `dc_timeout` | Délai max d'un appel `danger-claude` (s). |
```

Replace with:

```
| Exécution | `dc_timeout` | Délai max d'un appel `danger-claude`, et plafond d'une exécution de `mr-review` (s). |
```

- [ ] **Step 4: Rewrite the predecessor spec's exception paragraph**

In `docs/superpowers/specs/2026-08-10-live-worker-silence-invariant-design.md`, replace the paragraph that starts `**Acknowledged exception: \`reviewing\`.**` (around line 217, ending with `separate ticket.`) with:

```markdown
**`reviewing` was an acknowledged exception; Autodev #54 closed it.** `mr-review`
is an LLM review of the full MR diff, and at the time of this design it ran via
`Open3.capture3` with **no timeout**, at two call sites
(`PipelineMonitor::Reviewer#run_mr_review_command`,
`IssueProcessor::MrManager#execute_review` — the latter since found to be dead
code and deleted). Not being a danger-claude call, it contributed **no term** to
`longest_worker_timeout`: unlike `running_post_completion` there was no configured
timeout to fold into the max. Both sites got `dc_heartbeat!('mr-review')`
immediately before the call, which bounded silence in `reviewing` at one mr-review
run plus the 15 s pre-sleep rather than leaving it unbounded — but it did not
close the exposure, because nothing sized the window for a run that never
returned. #54 routes the call through `run_with_timeout`, capping it at
`dc_timeout` — a term already in the max — so `reviewing` is now covered like any
other state and `running_post_completion` is the only remaining exception. See
`2026-08-10-mr-review-timeout-design.md`.
```

Do not edit anything else in that file — it is the record of what was known when, and the rest of it stays as written.

- [ ] **Step 5: Run the full suite**

Run: `mise x ruby -- bundle exec rake test`

Expected: 0 failures, 0 errors. Quote the counts. Docs-only edits cannot break it, so a failure here means something from Task 1 or 2 regressed.

- [ ] **Step 6: RuboCop over the whole project**

Run: `mise x ruby -- rubocop`

Expected: the offense count must match `master`'s. `master` currently reports **46 offenses across 9 files**, all Rails-generated boilerplate (`bin/*`, `config/initializers/*`, `db/seeds.rb`, `app/helpers/application_helper.rb`, `app/models/application_record.rb`) — pre-existing and untouched by this branch. If you see a different count, one of your files introduced an offense: fix it, and never by editing `.rubocop.yml`.

- [ ] **Step 7: Check the French renders**

`docs/observability.md` is served through Redcarpet in the dashboard. You only deleted a bullet, so nothing new can break — but confirm the two surviving neighbours still parse, by rendering the file's `stuck_issues` section through the same config `HelpDoc` uses and checking for unbalanced `<code>` / stray `<em>` tags. If you cannot run the renderer, say so in your report rather than claiming it.

- [ ] **Step 8: Commit**

```bash
git add CHANGELOG.md docs/observability.md docs/usage/autodev-technical-usage.md docs/superpowers/specs/2026-08-10-live-worker-silence-invariant-design.md
git commit -F - <<'MSG'
docs: record that reviewing is no longer an exception (Autodev #54)

The predecessor ticket listed `reviewing` as the one STALLED_STATE its derived
window could not size, because mr-review had no timeout to fold into the max.
Capping it at dc_timeout closes that, so the exception bullet leaves
observability.md and the #50 spec's paragraph is rewritten to point here rather
than deleted — it is the account of what was known when, and a reader following
#50's reasoning needs to see where it went.

The technical guide's dc_timeout row now says what the setting actually caps: a
danger-claude call, and an mr-review run.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
```

---

## Verification

Before reporting the work done, confirm all three:

1. `mise x ruby -- bundle exec rake test` — 0 failures, 0 errors. Quote the counts.
2. `mise x ruby -- rubocop` — 46 offenses, the same 9 pre-existing boilerplate files as `master`.
3. `git log --oneline master..HEAD` — four commits (the spec, then Tasks 1–3).

Then hand back for review. The branch is `fix/54-mr-review-timeout`; the repo's convention is a merge commit per `fix/*` branch (e.g. `8249d2a`), and Skynet #54 gets its progress note.

---

## Addendum — Tasks 4 and 5 (final-review reversal)

The final whole-branch review measured `mr-review`'s real durations in the
production-copy DB: 317 completed reviews, longest **2641 s and successful**, ten
between 20 and 30 min. The 1800 s `dc_timeout` cap would kill roughly one
successful review a quarter, and because `review_count` only increments on
success, each kill costs five reruns and ends in a false
`review_failures_exhausted` — no review at all on the largest MRs. The spec's
"reuse `dc_timeout`" decision is reversed to a per-project `mr_review_timeout`;
see the spec's §1 for the data.

Tasks 1–3 stay as merged. These two tasks change the cap and its plumbing on top.

### Task 4: Per-project `mr_review_timeout`

**Files:**
- Create: `db/migrate/20260810000001_add_mr_review_timeout_to_projects.rb`
- Modify: `lib/autodev/config.rb` (add `MR_REVIEW_TIMEOUT`, extend `DB_BACKED_PROJECT_FIELDS`)
- Modify: `app/models/project.rb` (`POSITIVE_INT_FIELDS`, `SCALAR_CONFIG_KEYS`)
- Modify: `lib/autodev/project_validator.rb` (`validate_numerics!`'s field list)
- Modify: `app/services/yaml_project_importer.rb` (`CONFIG_KEYS`)
- Modify: `app/components/web/views/project_edit.rb` (`SECTIONS` execution group, `DEFAULT_HINT_VALUES`)
- Modify: `config/locales/web.fr.yml`, `config/locales/web.en.yml` (one description key each)
- Modify: `lib/autodev/process_runner.rb` (`run_with_timeout` gains `timeout:`)
- Modify: `lib/autodev/pipeline_monitor/reviewer.rb` (pass the resolved timeout, drop `label:`)
- Modify: `app/services/autodev/health_report.rb` (`longest_worker_timeout` gains the term)
- Test: `test/pipeline_monitor_review_heartbeat_test.rb` (extend), `test/models/project_config_test.rb` (extend), `test/services/health_report_stuck_window_test.rb` (extend)

**Interfaces:**
- Consumes: Task 1's `run_mr_review_command`, which currently calls `run_with_timeout('mr-review', ['-H', mr_url], chdir: Dir.pwd, label: 'mr-review')`.
- Produces: `Config::MR_REVIEW_TIMEOUT` (Integer, 3600); a `projects.mr_review_timeout` integer column; `run_with_timeout(cmd, args, chdir:, label: nil, timeout: nil)` where a nil `timeout:` keeps today's `dc_timeout` resolution.

**Two properties that must hold, and that the tests must pin:**

1. **The two danger-claude callers keep resolving `dc_timeout`.** The kwarg is additive: `timeout: nil` must fall through to `@project_config['dc_timeout'] || @config['dc_timeout'] || 600`, unchanged. A regression here silently re-caps every implementation call.
2. **Window-neutral at the default.** `2 × 3600 = 7200` is exactly the existing floor, so `stuck_active_after` must still return 7200 with no project overrides. A test that asserts a *changed* default window is asserting a bug.

- [ ] **Step 1: Write the failing tests**

In `test/pipeline_monitor_review_heartbeat_test.rb`, add to the existing class (its `stub_timeout_wrapper` helper already records `opts`):

```ruby
  # The cap is mr_review_timeout, not dc_timeout: a review's duration profile is
  # not an implementation call's (production data: 317 reviews, longest 2641s and
  # successful, against dc_timeout's 1800s default).
  def test_the_wrapper_is_called_with_the_baked_review_timeout
    calls = stub_timeout_wrapper(['', '', true])
    @harness.send(:run_mr_review_command, 'https://gitlab.example/mr/1')

    assert_equal Config::MR_REVIEW_TIMEOUT, calls.first[:opts][:timeout]
  end

  def test_a_project_override_wins_over_the_baked_review_timeout
    harness = Harness.new(issue: @issue, logger: StubLogger.new)
    harness.instance_variable_set(:@project_config, { 'path' => 'group/project', 'mr_review_timeout' => 5400 })
    harness.define_singleton_method(:command_exists?) { |_cmd| true }
    calls = []
    harness.define_singleton_method(:run_with_timeout) do |cmd, args, **opts|
      calls << { cmd: cmd, args: args, opts: opts }
      ['', '', true]
    end
    harness.send(:run_mr_review_command, 'https://gitlab.example/mr/1')

    assert_equal 5400, calls.first[:opts][:timeout]
  end

  # ProcessRunner builds its tag as "#{cmd} #{label}", so label: 'mr-review'
  # would read "mr-review mr-review timed out after 3600s".
  def test_no_redundant_label_is_passed
    calls = stub_timeout_wrapper(['', '', true])
    @harness.send(:run_mr_review_command, 'https://gitlab.example/mr/1')

    refute calls.first[:opts].key?(:label), 'cmd already names the command'
  end
```

In `test/models/project_config_test.rb`, add beside the existing positive-int assertions (the file's `project(...)` helper builds an unsaved `Project`):

```ruby
  def test_mr_review_timeout_must_be_a_positive_integer
    assert_predicate project(mr_review_timeout: 5400), :valid?
    refute_predicate project(mr_review_timeout: 0), :valid?
    refute_predicate project(mr_review_timeout: -1), :valid?
  end

  def test_mr_review_timeout_is_emitted_in_to_project_config
    cfg = project(mr_review_timeout: 5400).to_project_config

    assert_equal 5400, cfg['mr_review_timeout']
  end
```

In `test/services/health_report_stuck_window_test.rb`, add:

```ruby
  # 2 × the baked review default (3600) is exactly the 7200 floor, so adding the
  # term must not move the default window. A changed default here is a bug.
  test 'the baked review timeout does not move the default window' do
    assert_equal BASE, window
  end

  test 'derives from a project mr_review_timeout that exceeds the floor' do
    project(mr_review_timeout: 5400)

    assert_equal 10_800, window
  end

  test 'counts mr_review_timeout on a YAML-only project' do
    config = CONFIG.merge('projects' => [{ 'path' => 'group/yaml', 'mr_review_timeout' => 5400 }])

    assert_equal 10_800, window(config: config)
  end
```

- [ ] **Step 2: Run the three test files to verify they fail**

```bash
mise x ruby -- bundle exec rake test TEST=test/pipeline_monitor_review_heartbeat_test.rb
mise x ruby -- bundle exec rake test TEST=test/models/project_config_test.rb
mise x ruby -- bundle exec rake test TEST=test/services/health_report_stuck_window_test.rb
```

Expected: FAIL. The review tests get `NameError: uninitialized constant Config::MR_REVIEW_TIMEOUT` and a `nil` timeout; the model tests fail on an unknown attribute; the two new window derivations return 7200. `the baked review timeout does not move the default window` passes immediately — it is a guard, not a new behaviour.

- [ ] **Step 3: Migration**

Create `db/migrate/20260810000001_add_mr_review_timeout_to_projects.rb`:

```ruby
# frozen_string_literal: true

# Per-project cap for one `mr-review` run (Autodev #54). Separate from
# `dc_timeout` on measured grounds: on the production copy, 317 completed reviews
# ran up to 2641s *successfully*, against dc_timeout's 1800s default — reusing it
# would have killed a good review roughly once a quarter, and because
# review_count only increments on success each kill costs five reruns and ends in
# a false review_failures_exhausted.
#
# `if_not_exists`-aware so it is a no-op on a DB that already has the column,
# matching the other project-config migrations.
class AddMrReviewTimeoutToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :mr_review_timeout, :integer, if_not_exists: true
  end
end
```

- [ ] **Step 4: The baked default and the config plumbing**

In `lib/autodev/config.rb`, next to `POST_COMPLETION_TIMEOUT`:

```ruby
  # Baked default for the per-project `mr_review_timeout`, in seconds. Sized on
  # production data rather than symmetry with dc_timeout: the longest successful
  # mr-review on record took 2641s (Autodev #54).
  MR_REVIEW_TIMEOUT = 3600
```

And add `mr_review_timeout` to `DB_BACKED_PROJECT_FIELDS` (so setting it under a
YAML `projects:` entry emits the same deprecation warning as its siblings).

In `app/models/project.rb`, add `mr_review_timeout` to **`POSITIVE_INT_FIELDS`**
and to **`SCALAR_CONFIG_KEYS`**. Nothing else in that file needs touching:
`CONFIG_INTEGER_FIELDS` is derived from `POSITIVE_INT_FIELDS`, which is what
carries the field into the validations, `ProjectsController`'s
`integer_or_nil` handling, and the edit form's input type.

In `lib/autodev/project_validator.rb`, add `mr_review_timeout` to
`validate_numerics!`'s field list.

In `app/services/yaml_project_importer.rb`, add `mr_review_timeout` to
`CONFIG_KEYS`.

- [ ] **Step 5: The edit form and its two locale keys**

In `app/components/web/views/project_edit.rb`, add `mr_review_timeout` to
`SECTIONS`' execution group (after `post_completion_timeout`), and
`mr_review_timeout: 3600` to `DEFAULT_HINT_VALUES`.

In `config/locales/web.fr.yml`, beside `web_project_edit_desc_post_completion_timeout`:

```yaml
  web_project_edit_desc_mr_review_timeout: Délai maximum d'une exécution de mr-review, en secondes. Au-delà, la review est interrompue et comptée comme un échec.
```

In `config/locales/web.en.yml`, at the matching position:

```yaml
  web_project_edit_desc_mr_review_timeout: Maximum time for a single mr-review run, in seconds. Past it the review is killed and counted as a failure.
```

- [ ] **Step 6: The `timeout:` kwarg**

In `lib/autodev/process_runner.rb`, change `run_with_timeout`'s signature and its
first line only:

```ruby
  # `timeout:` overrides the danger-claude cap for a caller that runs a different
  # program (Autodev #54: mr-review has its own, measured profile). Left nil, the
  # resolution is unchanged for the two danger-claude entry points.
  def run_with_timeout(cmd, args, chdir:, label: nil, timeout: nil)
    timeout = (timeout || @project_config['dc_timeout'] || @config['dc_timeout'] || 600).to_i
```

Everything below that line stays as it is.

- [ ] **Step 7: Use it in the reviewer**

In `lib/autodev/pipeline_monitor/reviewer.rb`, replace the `run_with_timeout`
call inside `run_mr_review_command` and add the resolver. Keep the surrounding
comment block, amending its `chdir`/cap sentences to match:

```ruby
      _, err, ok = run_with_timeout('mr-review', ['-H', mr_url], chdir: Dir.pwd,
                                    timeout: mr_review_timeout)
```

```ruby
    # Per-project override, else the baked default. A review's duration profile is
    # not an implementation call's, which is why this is not dc_timeout.
    def mr_review_timeout
      (@project_config['mr_review_timeout'] || ::Config::MR_REVIEW_TIMEOUT).to_i
    end
```

Note the `label:` argument is **dropped**: `ProcessRunner`'s tag is
`"#{cmd} #{label}"`, so passing `'mr-review'` produced `mr-review mr-review timed
out after …` in the raised message, the log line and the `@dc_stdout` header.

- [ ] **Step 8: The `HealthReport` term**

In `app/services/autodev/health_report.rb`, add the field to all three sources
inside `longest_worker_timeout` / `yaml_project_timeouts`: the baked
`::Config::MR_REVIEW_TIMEOUT`, `Project.maximum(:mr_review_timeout)`, and
`project['mr_review_timeout']` in the YAML branch. Amend the method's comment so
it names the third timeout and states that `2 × 3600` equals the existing floor,
so the default window is unchanged.

- [ ] **Step 9: Run the three test files, then the full suite**

```bash
mise x ruby -- bundle exec rake test TEST=test/pipeline_monitor_review_heartbeat_test.rb
mise x ruby -- bundle exec rake test TEST=test/models/project_config_test.rb
mise x ruby -- bundle exec rake test TEST=test/services/health_report_stuck_window_test.rb
mise x ruby -- bundle exec rake test
```

Expected: all pass; the full suite reports 0 failures and 0 errors. The suite is
the gate that proves property 1 above — `test/danger_claude_runner_heartbeat_test.rb`,
`test/services/yaml_project_importer_config_test.rb` and
`test/controllers/projects_controller_edit_test.rb` all exercise paths the new
field touches. Quote the counts.

- [ ] **Step 10: RuboCop**

```bash
mise x ruby -- rubocop db/migrate/20260810000001_add_mr_review_timeout_to_projects.rb lib/autodev/config.rb app/models/project.rb lib/autodev/project_validator.rb app/services/yaml_project_importer.rb app/components/web/views/project_edit.rb lib/autodev/process_runner.rb lib/autodev/pipeline_monitor/reviewer.rb app/services/autodev/health_report.rb test/pipeline_monitor_review_heartbeat_test.rb test/models/project_config_test.rb test/services/health_report_stuck_window_test.rb
```

Expected: no offenses.

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -F - <<'MSG'
feat: give mr-review its own per-project timeout (Autodev #54)

Capping mr-review at dc_timeout was window-cheap but wrong on the data. On the
production copy, 317 completed reviews ran up to 2641s *successfully*, ten of
them between 20 and 30 minutes, against dc_timeout's 1800s default — so the cap
would have killed a good review roughly once a quarter, with six more within
seven minutes of the edge, and review duration tracks MR size.

The cost of a kill is worse than a lost review: review_count only increments on
success, so the next poll reruns mr-review from scratch, and five rounds later
give_up_reviewing forces done, sets label_done, reassigns the author and flags
review_failures_exhausted. A false "exhausted" alarm and no review at all, on
precisely the largest MRs, after ~2.5h of quota.

mr_review_timeout is therefore its own per-project column, defaulting to
Config::MR_REVIEW_TIMEOUT (3600, covering every observed run), with
run_with_timeout gaining an additive `timeout:` kwarg — nil keeps the dc_timeout
resolution for its two danger-claude callers — and longest_worker_timeout gaining
a term so a project raising its review cap widens the stuck-window automatically.
The default window does not move: 2 × 3600 is exactly the existing 7200 floor.

Also drops the redundant `label: 'mr-review'`: ProcessRunner tags as
"#{cmd} #{label}", so it read "mr-review mr-review timed out after …".

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
```

### Task 5: Docs for the reversal

**Files:**
- Modify: `CHANGELOG.md` (the `[Unreleased]` `### Fixed` bullet added by Task 3)
- Modify: `docs/usage/autodev-technical-usage.md` (the `dc_timeout` row, plus a new `mr_review_timeout` row)
- Modify: `docs/observability.md` (the `stuck_issues` bullet's list of timeouts)

**Interfaces:** consumes Task 4; produces nothing.

- [ ] **Step 1: Correct the changelog bullet**

Task 3's bullet says the cap is `dc_timeout` and that `HealthReport` needed no
change. Both are now false. Rewrite that bullet so it states: `mr-review` runs
under `run_with_timeout` capped by a new per-project `mr_review_timeout` (baked
default 3600, sized on 317 production reviews whose longest successful run took
2641 s); `longest_worker_timeout` gains the term, which is window-neutral at the
default because `2 × 3600` is the existing 7200 floor; `reviewing` leaves the
exceptions list, leaving `running_post_completion` as the only remaining one; a
timeout stays non-fatal and counts a review failure. Keep the sentence about the
deleted `MrManager` trio, and drop the now-wrong "~25 lines" count in favour of
"a parallel review path with no caller".

- [ ] **Step 2: The technical guide's config table**

In `docs/usage/autodev-technical-usage.md`, revert the `dc_timeout` row to its
original wording (it no longer caps mr-review):

```
| Exécution | `dc_timeout` | Délai max d'un appel `danger-claude` (s). |
```

And add a row after it, in the same French register:

```
| Exécution | `mr_review_timeout` | Délai max d'une exécution de `mr-review` (s, défaut 3600). Au-delà, la review est interrompue et comptée comme un échec ; 5 échecs consécutifs clôturent la demande et la réassignent à son auteur. |
```

- [ ] **Step 3: The observability bullet**

In `docs/observability.md`'s `stuck_issues` bullet, the window is described as
taken over `dc_timeout` **et** `post_completion_timeout`. Add `mr_review_timeout`
to that enumeration, keeping each identifier in its own backtick span (never
nested — Redcarpet breaks on that).

- [ ] **Step 4: Full suite and RuboCop**

```bash
mise x ruby -- bundle exec rake test
mise x ruby -- rubocop
```

Expected: 0 failures, 0 errors; RuboCop at master's 46-offence baseline across the
same 9 untouched boilerplate files. Quote both.

- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md docs/usage/autodev-technical-usage.md docs/observability.md
git commit -F - <<'MSG'
docs: record mr_review_timeout as its own setting (Autodev #54)

The changelog bullet and the technical guide were written when the cap was
dc_timeout; production data reversed that decision, so both said something false.
The guide's dc_timeout row goes back to its original wording and mr_review_timeout
gets its own row — including the consequence an operator actually needs: past the
cap the review is killed and counted as a failure, and five consecutive failures
close the request and reassign it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
```
