# Live-worker silence invariant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bound how long a live worker can stay silent, so `dispatch_dormant_audit` can no longer reposition a row while an `IssueProcessJob` holds the concurrency lock on it (Autodev #50).

**Architecture:** Two independent halves. (1) Every danger-claude call writes a DB-only `activity_events` row (`kind: 'heartbeat'`) from `DangerClaudeRunner`, the single funnel every call passes through — so a live worker's silence is one call long whatever loop it sits in, including `PipelineFixer`'s N-jobs loop, which today emits nothing per iteration. (2) `HealthReport#stuck_active_after` becomes `max(configured, 2 × longest configured timeout)`, so a project raising `dc_timeout` or `post_completion_timeout` widens the window automatically instead of silently breaking the invariant. Both readers of that window — the "Issues bloquées" health card and `DormantAudit#active_window` — already share it and move together.

**Tech Stack:** Rails 8.1.3, ActiveRecord + SQLite, Minitest (`test/**/*_test.rb`), AASM, Phlex views.

**Spec:** `docs/superpowers/specs/2026-08-10-live-worker-silence-invariant-design.md`

**Worktree:** `fix/50-worker-silence-invariant` (already created, branched from `master` at `e46220c`, spec committed as `5e93bb2`).

## Global Constraints

- **TDD.** Write the failing test, run it, watch it fail for the right reason, then implement.
- **RuboCop must pass**: `mise x ruby -- rubocop` from the worktree root. Never edit any `.rubocop.yml`.
- **Conventional Commits**: `<type>: <description>` (`feat`, `fix`, `refactor`, `test`, `docs`, `chore`) plus a body explaining the why. End every commit message with `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- **`CHANGELOG.md` `[Unreleased]`** is updated in the same pass (Task 7).
- **No user-facing string is added by this change.** The heartbeat row is never rendered, so it needs no `config/locales/*` key. If you find yourself adding a literal a user could read, stop — it must go through `Locales.t` / `t_web` in **both** `fr` and `en`.
- **Test commands** (run from the worktree root):
  - one file: `mise x ruby -- bundle exec rake test TEST=test/<file>_test.rb`
  - one test: `mise x ruby -- bundle exec rake test TEST=test/<file>_test.rb TESTOPTS="--name=/<pattern>/"`
  - full suite: `mise x ruby -- bundle exec rake test`
- **Two test harnesses exist; pick the one the neighbouring tests use.**
  - `require_relative 'test_helper'` + `include DatabaseTestHelper` → `Minitest::Test`, **non-transactional**, `def test_x` methods. Wipes `issues` + `activity_events` at setup and teardown. Used by root-level tests.
  - `require_relative '../rails_helper'` → `ActiveSupport::TestCase` / `ActionDispatch::IntegrationTest`, **transactional** (rows roll back), `test 'name' do` blocks. Used by `test/services/` and `test/controllers/`.
- **Never widen `Issue.without_activity_since`'s filters.** It must keep counting *every* `activity_events` row: that is the mechanism this plan relies on. Only rendering paths filter the heartbeat out.

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `app/models/activity_event.rb` | Declares the `heartbeat` kind, the `user_visible` scope (the one place that says "this kind is machinery"), and keeps heartbeats off the SSE feed | 1 |
| `test/activity_event_heartbeat_test.rb` | New. The heartbeat's contract: invisible to renderers, visible to the staleness query | 1 |
| `lib/autodev/activity_logger.rb` | `ActivityLogger.heartbeat!` — DB-only write, no GitLab round-trip | 2 |
| `lib/autodev/danger_claude_runner.rb` | Emits the heartbeat at the start of both danger-claude entry points | 2 |
| `test/danger_claude_runner_heartbeat_test.rb` | New. Harness over the two entry points with the subprocess stubbed | 2 |
| `app/controllers/issues_controller.rb` | `events_for` renders `user_visible` events only | 3 |
| `app/helpers/web/helpers.rb` | Sparkline excludes the heartbeat kind | 3 |
| `test/controllers/issues_controller_heartbeat_test.rb` | New. The issue timeline hides heartbeats | 3 |
| `test/weekly_activity_counts_test.rb` | Extended. The sparkline ignores heartbeats | 3 |
| `lib/autodev/config.rb` | `Config::POST_COMPLETION_TIMEOUT` — the baked per-project default, in a file `HealthReport` can already load | 4 |
| `lib/autodev/pipeline_monitor/post_completion.rb` | Reads that constant instead of a bare `300` | 4 |
| `app/services/autodev/health_report.rb` | Derives `stuck_active_after` from the longest configured timeout; reports the effective window | 4 |
| `test/services/health_report_stuck_window_test.rb` | New. The derivation table | 4 |
| `test/dormant_audit_selection_test.rb` | Extended. The regression the ticket asked for | 5 |
| `app/services/autodev/dormant_audit.rb` | Comment cross-reference (no behaviour change — it delegates) | 5 |
| `CHANGELOG.md`, `docs/observability.md`, `docs/usage/autodev-technical-usage.md`, `docs/superpowers/specs/2026-08-07-dormant-rows-audit-design.md` | Docs | 6 |

---

### Task 1: The `heartbeat` kind and the `user_visible` scope

The model-side contract, before anything writes one: the kind exists, renderers have one way to exclude it, and the SSE feed does not carry it. `broadcast_to_event_bus`'s existing guard is not enough — it only skips rows with a NULL `issue_id`, and a heartbeat carries one.

**Files:**
- Modify: `app/models/activity_event.rb:11-14` (KINDS), `:29` (after the callback declaration, add the scope), `:49-59` (`broadcast_to_event_bus`)
- Test: `test/activity_event_heartbeat_test.rb` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: `ActivityEvent::KINDS` includes `'heartbeat'`; `ActivityEvent.user_visible` → relation excluding `kind: 'heartbeat'`. Tasks 2 and 3 depend on both.

- [ ] **Step 1: Write the failing test**

Create `test/activity_event_heartbeat_test.rb`:

```ruby
# frozen_string_literal: true

require_relative 'test_helper'

# The heartbeat kind's contract (Autodev #50). A heartbeat row exists for one
# reader — Issue.without_activity_since, which bounds how long a live worker may
# stay silent before dispatch_dormant_audit repositions its row. It is machinery,
# not activity anyone asked to see, so it must stay out of every rendering path
# while remaining visible to the staleness query.
class ActivityEventHeartbeatTest < Minitest::Test
  include DatabaseTestHelper

  def setup
    setup_database
    @issue = create_issue(status: 'implementing', created_at: 4.hours.ago)
  end

  def heartbeat(created_at: Time.now.utc)
    ActivityEvent.create!(issue_id: @issue.id, kind: 'heartbeat', level: 'info',
                          payload_json: JSON.generate(event: 'dc_call', label: '-p'),
                          created_at: created_at)
  end

  def test_heartbeat_is_an_accepted_kind
    assert_includes ActivityEvent::KINDS, 'heartbeat'
  end

  def test_user_visible_excludes_heartbeats
    heartbeat
    transition = ActivityEvent.create!(issue_id: @issue.id, kind: 'transition',
                                       level: 'info', payload_json: '{}')

    assert_equal [transition.id], ActivityEvent.user_visible.pluck(:id)
  end

  # A heartbeat carries an issue_id, so the NULL-issue_id guard does not cover
  # it: without an explicit kind check, /stream would emit one Turbo Stream
  # frame per danger-claude call.
  def test_heartbeat_is_not_broadcast_to_the_event_bus
    published = []
    Web::EventBus.stub(:publish, ->(event) { published << event }) do
      heartbeat
      ActivityEvent.create!(issue_id: @issue.id, kind: 'transition', payload_json: '{}')
    end

    assert_equal %w[transition], published.map(&:kind)
  end

  # The load-bearing assertion: this is why the row is written at all. A row
  # whose only activity is a heartbeat inside the window is NOT stale.
  def test_a_heartbeat_counts_as_activity_for_the_staleness_query
    heartbeat(created_at: 10.minutes.ago)

    stale = Issue.where(status: 'implementing').without_activity_since(2.hours.ago)

    assert_empty stale.pluck(:id)
  end

  def test_an_old_heartbeat_does_not_hide_a_stale_row
    heartbeat(created_at: 4.hours.ago)

    stale = Issue.where(status: 'implementing').without_activity_since(2.hours.ago)

    assert_equal [@issue.id], stale.pluck(:id)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise x ruby -- bundle exec rake test TEST=test/activity_event_heartbeat_test.rb`

Expected: FAIL. `test_heartbeat_is_an_accepted_kind` fails on the missing kind, `test_user_visible_excludes_heartbeats` raises `NoMethodError: undefined method 'user_visible'`, and `test_heartbeat_is_not_broadcast_to_the_event_bus` fails with `["heartbeat", "transition"]` — the heartbeat reaching the bus is exactly the bug.

- [ ] **Step 3: Add the kind, the scope and the broadcast guard**

In `app/models/activity_event.rb`, replace the `KINDS` declaration and its comment:

```ruby
  # `poller`, `error` and `usage` are system events (issue_id nil): heartbeats,
  # cycle-failure markers, and the Claude-quota verdict Autodev::UsageGate
  # persists once per cycle (Autodev #46). `heartbeat` is different — it carries
  # an issue_id: it is the per-danger-claude-call liveness marker that bounds a
  # live worker's silence (Autodev #50, DangerClaudeRunner#dc_heartbeat!).
  KINDS = %w[transition danger_claude poller error usage heartbeat].freeze
```

Immediately after the `after_create_commit :broadcast_to_event_bus` line, add:

```ruby
  # Rows that exist for one reader only: Issue.without_activity_since, which
  # bounds how long a live worker may stay silent before dispatch_dormant_audit
  # repositions its row (Autodev #50). They are machinery, not activity anyone
  # asked to see, so every path that *renders* events goes through this scope —
  # one definition rather than a `where.not` repeated per consumer. The
  # staleness query itself must NOT use it: counting the heartbeat is the whole
  # mechanism.
  scope :user_visible, -> { where.not(kind: 'heartbeat') }
```

Replace `broadcast_to_event_bus`:

```ruby
  def broadcast_to_event_bus
    return unless defined?(Web::EventBus)
    # System events (poller heartbeats, cycle-failure markers) carry no issue_id.
    # They feed Autodev::HealthReport, not the per-issue SSE activity feed — and
    # broadcasting a 5-minute heartbeat would spam /stream. Skip them here.
    return if issue_id.nil?
    # danger-claude liveness markers DO carry an issue_id, so the guard above
    # does not cover them: one frame per call would flood the feed (Autodev #50).
    return if kind == 'heartbeat'

    Web::EventBus.publish(self)
  rescue StandardError
    nil
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mise x ruby -- bundle exec rake test TEST=test/activity_event_heartbeat_test.rb`

Expected: PASS, 5 runs, 0 failures.

- [ ] **Step 5: Check the existing model test still passes**

Run: `mise x ruby -- bundle exec rake test TEST=test/activity_event_test.rb`

Expected: PASS, unchanged.

- [ ] **Step 6: RuboCop**

Run: `mise x ruby -- rubocop app/models/activity_event.rb test/activity_event_heartbeat_test.rb`

Expected: no offenses.

- [ ] **Step 7: Commit**

```bash
git add app/models/activity_event.rb test/activity_event_heartbeat_test.rb
git commit -F - <<'MSG'
feat: add the heartbeat activity kind and the user_visible scope (Autodev #50)

The dormant audit's active arm treats "no activity_events row for
stuck_active_after" as "the worker is dead". Nothing guarantees that today: a
worker can be alive and silent for longer, so the audit can reposition a row a
job still holds. The fix records liveness per danger-claude call, which needs a
kind of its own.

The row carries an issue_id, so broadcast_to_event_bus's NULL-issue_id guard
does not cover it — without an explicit check /stream would emit one frame per
call. Renderers exclude it through a single `user_visible` scope rather than a
`where.not` copied per consumer; Issue.without_activity_since deliberately does
not, since counting the heartbeat is the entire mechanism.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
```

---

### Task 2: Emit the heartbeat on every danger-claude call

`danger_claude_prompt` and `danger_claude_commit` are the only two methods in the codebase that spawn danger-claude — every call site (`Implementer`, `ParallelRunner`, `SpecChecker`, `QuestionHandler`, `FixCycle`, `PipelineFixer`, `Evaluator`, `RepoRebaser`, `GitOperations`) goes through one of them, and both end at `run_with_timeout('danger-claude', …)`, which owns the `dc_timeout` kill. Writing the marker here makes the bound hold for every loop, present and future.

**Files:**
- Modify: `lib/autodev/activity_logger.rb` (add `self.heartbeat!` next to `self.warn_event`, around `:44-51`)
- Modify: `lib/autodev/danger_claude_runner.rb:47-59` (`danger_claude_prompt`), `:67-77` (`danger_claude_commit`), and add the private `dc_heartbeat!` helper
- Test: `test/danger_claude_runner_heartbeat_test.rb` (create)

**Interfaces:**
- Consumes: `ActivityEvent::KINDS` includes `'heartbeat'` (Task 1).
- Produces: `ActivityLogger.heartbeat!(issue, label)` → writes one `ActivityEvent` (`kind: 'heartbeat'`, `level: 'info'`, payload `{"event":"dc_call","label":<label>}`), returns `nil` and never raises; no-op when `issue` is nil. `DangerClaudeRunner#dc_heartbeat!(label)` (private) forwards `@dc_issue`.

- [ ] **Step 1: Write the failing test**

Create `test/danger_claude_runner_heartbeat_test.rb`:

```ruby
# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/port_allocator'
require 'autodev/danger_claude_runner'

# Every danger-claude call records liveness (Autodev #50).
#
# The dormant audit's active arm reads "no activity_events row for
# stuck_active_after" as "the worker died". Per-state business events do not
# bound that: PipelineFixer emits one event on entering fixing_pipeline, then
# makes two calls per failed job with nothing in between, so silence there is
# N × 2 × dc_timeout. Recording it per call — in the one place every call passes
# through — bounds it at one call regardless of the loop.
class DangerClaudeRunnerHeartbeatTest < Minitest::Test
  include DatabaseTestHelper

  # Host for DangerClaudeRunner's two danger-claude entry points with the
  # subprocess stubbed: what is under test is the activity row the call writes,
  # not danger-claude itself.
  class Harness
    include DangerClaudeRunner

    attr_reader :timeout_calls

    def initialize(issue:, logger:)
      init_runner(client: nil, config: { 'dc_timeout' => 1800 },
                  project_config: { 'path' => 'group/project' },
                  logger: logger, token: 'tok')
      @dc_issue = issue
      @timeout_calls = []
    end

    # ProcessRunner#run_with_timeout stand-in. Returns the envelope
    # danger-claude emits under --output-format json, so capture_session_and_text
    # parses it instead of taking the parse-failed branch (which would write a
    # warn event of its own and muddy the assertions).
    def run_with_timeout(cmd, _args, chdir:, label: nil)
      @timeout_calls << { cmd: cmd, chdir: chdir, label: label }
      ['{"result":"ok","session_id":"s1"}', '', true]
    end
  end

  def setup
    setup_database
    @issue = create_issue(status: 'implementing')
    @harness = Harness.new(issue: @issue, logger: StubLogger.new)
  end

  def heartbeats
    ActivityEvent.where(issue_id: @issue.id, kind: 'heartbeat').order(:id).to_a
  end

  def test_prompt_writes_one_heartbeat
    @harness.send(:danger_claude_prompt, '/tmp/wd', 'do the thing', label: '-p (implement code)')

    assert_equal 1, heartbeats.size
    assert_equal '-p (implement code)', heartbeats.first.payload['label']
  end

  def test_commit_writes_one_heartbeat
    @harness.send(:danger_claude_commit, '/tmp/wd', label: '-c (pipeline fix: rubocop)')

    assert_equal 1, heartbeats.size
    assert_equal '-c (pipeline fix: rubocop)', heartbeats.first.payload['label']
  end

  # The bound is per call, so a loop of N calls leaves N markers — this is what
  # keeps PipelineFixer's N-jobs loop under the window.
  def test_each_call_in_a_loop_leaves_its_own_marker
    3.times do |i|
      @harness.send(:danger_claude_prompt, '/tmp/wd', "fix job #{i}", label: "-p (job #{i})")
      @harness.send(:danger_claude_commit, '/tmp/wd', label: "-c (job #{i})")
    end

    assert_equal 6, heartbeats.size
  end

  # No GitLab round-trip: the client is nil, so any attempt to post would raise.
  # The activity note on the issue is deliberately left alone.
  def test_no_gitlab_call_is_made
    @harness.send(:danger_claude_prompt, '/tmp/wd', 'do the thing')

    assert_equal 1, heartbeats.size
  end

  def test_no_issue_tracked_is_a_no_op
    harness = Harness.new(issue: nil, logger: StubLogger.new)

    harness.send(:danger_claude_prompt, '/tmp/wd', 'do the thing')

    assert_empty ActivityEvent.where(kind: 'heartbeat')
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise x ruby -- bundle exec rake test TEST=test/danger_claude_runner_heartbeat_test.rb`

Expected: FAIL — every assertion on `heartbeats.size` gets `0`. (`test_no_issue_tracked_is_a_no_op` passes vacuously; that is fine, it guards the implementation you are about to write.)

- [ ] **Step 3: Add `ActivityLogger.heartbeat!`**

In `lib/autodev/activity_logger.rb`, immediately after `self.warn_event` (which ends around line 51), add:

```ruby
  # Liveness marker for one danger-claude call (Autodev #50). DB only — no
  # GitLab note update, so it costs one INSERT and leaves the issue thread
  # untouched — and no locale entry, because nothing renders it:
  # Issue.without_activity_since is its only reader.
  #
  # This is what bounds a live worker's silence. Per-state business events do
  # not: PipelineFixer emits one event on entering fixing_pipeline, then loops
  # over N failed jobs with two calls each and nothing in between.
  #
  # No-op without a tracked issue, same contract as warn_event.
  def self.heartbeat!(issue, label)
    return unless issue

    ActivityEvent.create(issue_id: issue.id, kind: 'heartbeat', level: 'info',
                         payload_json: JSON.generate(event: 'dc_call', label: label))
    nil
  rescue StandardError
    nil
  end
```

Do **not** add it to the `private_class_method` list at the bottom of the file — `DangerClaudeRunner` calls it from another module.

- [ ] **Step 4: Emit it from both entry points**

In `lib/autodev/danger_claude_runner.rb`, add the `dc_heartbeat!` call to `danger_claude_prompt`, immediately before `run_with_timeout`:

```ruby
    log_dc_prompt(prompt, agent)
    dc_heartbeat!(label)
    out, err, ok = run_with_timeout('danger-claude', args, chdir: work_dir, label: label)
```

Same in `danger_claude_commit`:

```ruby
    args += ['-c']
    dc_heartbeat!(label)
    out, err, ok = run_with_timeout('danger-claude', args, chdir: work_dir, label: label)
```

And add the helper, next to `log_dc_prompt`:

```ruby
  # The invariant dispatch_dormant_audit rests on (Autodev #50): a live worker's
  # silence must stay under HealthReport#stuck_active_after, or the audit can
  # reposition a row while an IssueProcessJob holds the concurrency lock on it —
  # silently, since the model runs with `whiny_transitions: false`.
  #
  # Business events do not provide that bound (PipelineFixer: one event per
  # state, two calls per failed job), so liveness is recorded per call, here,
  # where every danger-claude call in the codebase funnels through.
  #
  # Before the call, not after: the clock resets when the call starts, so the
  # longest possible gap is one call's dc_timeout plus loop overhead — whatever
  # the surrounding loop does.
  def dc_heartbeat!(label)
    ActivityLogger.heartbeat!(@dc_issue, label)
  end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mise x ruby -- bundle exec rake test TEST=test/danger_claude_runner_heartbeat_test.rb`

Expected: PASS, 5 runs, 0 failures.

- [ ] **Step 6: RuboCop**

Run: `mise x ruby -- rubocop lib/autodev/activity_logger.rb lib/autodev/danger_claude_runner.rb test/danger_claude_runner_heartbeat_test.rb`

Expected: no offenses. If `Metrics/ModuleLength` or `Metrics/AbcSize` trips on `danger_claude_runner.rb`, do **not** edit `.rubocop.yml` — the two added lines are inside existing methods, so the likely offender is module length: move `dc_heartbeat!` next to `log_dc_prompt` (as specified) rather than adding a new section, and if it still trips, report it rather than restructuring the module in this task.

- [ ] **Step 7: Commit**

```bash
git add lib/autodev/activity_logger.rb lib/autodev/danger_claude_runner.rb test/danger_claude_runner_heartbeat_test.rb
git commit -F - <<'MSG'
fix: record liveness on every danger-claude call (Autodev #50)

fixing_pipeline could go silent for longer than the dormant audit's 2h window
at default settings: PipelineFixer emits :pipeline_fixing once on entry, then
loops over the N failed jobs with two danger-claude calls each (prompt then
commit) and no activity event in between, so silence reaches N × 2 ×
dc_timeout — 3600s per job at the default 1800. Two slow jobs reach the window,
three exceed it, and the calls do hit their timeout in practice (the documented
reason dc_timeout went from 600 to 1800).

Past that window dispatch_dormant_audit repositions the row under the live
worker. In this particular state the outcome coincides with the transition the
worker was heading to, so the damage is usually invisible — but a closure or an
unassignment inside the window sends the row to closed/done while the worker
keeps pushing, and any future multi-call loop reopens the general case.

MrFixer showed the fix: one event per iteration bounds it. Rather than patch
each loop, the marker is written where every danger-claude call funnels, so the
bound holds for loops not yet written. DB-only: no GitLab round-trip, nothing
rendered, one INSERT per call.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
```

---

### Task 3: Keep heartbeats out of the two rendering paths

`ActivityEvent.user_visible` exists; the two consumers that render events must use it. Without this the issue timeline grows a row per danger-claude call and the dashboard sparkline counts them as activity.

**Files:**
- Modify: `app/controllers/issues_controller.rb:191-195` (`events_for`)
- Modify: `app/helpers/web/helpers.rb:227-234` (`weekly_activity_counts`)
- Test: `test/controllers/issues_controller_heartbeat_test.rb` (create)
- Test: `test/weekly_activity_counts_test.rb` (extend)

**Interfaces:**
- Consumes: `ActivityEvent.user_visible` (Task 1), `kind: 'heartbeat'` rows (Task 2).
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Write the failing controller test**

Create `test/controllers/issues_controller_heartbeat_test.rb`:

```ruby
# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'

# The issue timeline must not show danger-claude liveness markers (Autodev #50).
# They are written once per call — a single implementation run can produce a
# dozen — and carry no message anyone asked for. The activity count in the
# section heading is rendered from the same list, so it is the assertion that
# pins the filtering rather than the markup.
class IssuesControllerHeartbeatTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: 'admin@modulotech.fr', name: 'Admin', admin: true)
    @issue = Issue.create!(project_path: 'group/proj', issue_iid: 600, status: 'implementing')
    ActivityEvent.create!(issue_id: @issue.id, kind: 'transition', level: 'info',
                          payload_json: JSON.generate(message: 'visible-entry'))
    2.times do
      ActivityEvent.create!(issue_id: @issue.id, kind: 'heartbeat', level: 'info',
                            payload_json: JSON.generate(event: 'dc_call', label: '-p'))
    end
    sign_in @admin
  end

  def test_timeline_does_not_render_heartbeat_rows
    get "/issues/#{@issue.id}"

    assert_response :success
    assert_no_match(/heartbeat/, response.body)
  end

  # `web_issue_activity` renders as "Activity (%{count})" from the same list, so
  # the heading is where a leaked heartbeat shows up as a number.
  def test_activity_count_ignores_heartbeats
    get "/issues/#{@issue.id}"

    assert_response :success
    assert_match 'visible-entry', response.body
    assert_match(/Activity \(1\)/, response.body)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise x ruby -- bundle exec rake test TEST=test/controllers/issues_controller_heartbeat_test.rb`

Expected: FAIL — `test_timeline_does_not_render_heartbeat_rows` finds `heartbeat` in the body (`event_kind_label` falls back to the raw kind for an unknown one), and the activity count reads 3.

- [ ] **Step 3: Filter in `events_for`**

In `app/controllers/issues_controller.rb`, replace `events_for`:

```ruby
  # `user_visible` drops the danger-claude liveness markers (Autodev #50): one
  # per call, no message, written only so the dormant audit can tell a live
  # worker from a dead one.
  def events_for(issue_model)
    activity_events_dataset.user_visible
                           .where(issue_id: issue_model.id)
                           .order(created_at: :desc, id: :desc)
                           .limit(200).to_a
  end
```

- [ ] **Step 4: Run it to verify it passes**

Run: `mise x ruby -- bundle exec rake test TEST=test/controllers/issues_controller_heartbeat_test.rb`

Expected: PASS, 2 runs, 0 failures.

- [ ] **Step 5: Write the failing sparkline test**

In `test/weekly_activity_counts_test.rb`, add (the file's `insert_event` helper already takes a `kind:`):

```ruby
  # Liveness markers (Autodev #50) are written once per danger-claude call, so
  # counting them would make the sparkline measure worker chatter instead of
  # work done.
  def test_heartbeat_events_are_excluded
    insert_event("#{Time.zone.today} 12:00:00", kind: 'heartbeat')
    insert_event("#{Time.zone.today} 12:00:00", kind: 'transition')

    assert_equal 1, @helper.weekly_activity_counts.sum
  end
```

- [ ] **Step 6: Run it to verify it fails**

Run: `mise x ruby -- bundle exec rake test TEST=test/weekly_activity_counts_test.rb TESTOPTS="--name=/heartbeat/"`

Expected: FAIL, `Expected: 1, Actual: 2`.

- [ ] **Step 7: Exclude the kind from the sparkline**

In `app/helpers/web/helpers.rb`, in `weekly_activity_counts`, replace the exclusion line:

```ruby
            # system heartbeats/markers (issue_id nil) + danger-claude liveness
            # markers (Autodev #50), which measure chatter, not work done
            .where.not(kind: %w[poller error heartbeat])
```

- [ ] **Step 8: Run both test files to verify they pass**

Run: `mise x ruby -- bundle exec rake test TEST=test/weekly_activity_counts_test.rb`
Then: `mise x ruby -- bundle exec rake test TEST=test/controllers/issues_controller_heartbeat_test.rb`

Expected: PASS both, 0 failures.

- [ ] **Step 9: RuboCop**

Run: `mise x ruby -- rubocop app/controllers/issues_controller.rb app/helpers/web/helpers.rb test/weekly_activity_counts_test.rb test/controllers/issues_controller_heartbeat_test.rb`

Expected: no offenses.

- [ ] **Step 10: Commit**

```bash
git add app/controllers/issues_controller.rb app/helpers/web/helpers.rb test/weekly_activity_counts_test.rb test/controllers/issues_controller_heartbeat_test.rb
git commit -F - <<'MSG'
fix: hide danger-claude liveness markers from the UI (Autodev #50)

The heartbeat rows exist for Issue.without_activity_since, not for people: one
per danger-claude call, no message, a dozen for a single implementation run.
Left unfiltered they pad the issue timeline (and its activity count, rendered
from the same list) and make the dashboard sparkline measure worker chatter
instead of work delivered.

Both consumers now go through ActivityEvent.user_visible / the kind exclusion.
The staleness query deliberately keeps counting them.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
```

---

### Task 4: Derive `stuck_active_after` from the longest configured timeout

With the heartbeat in place, silence is one danger-claude call long — except for `running_post_completion`, whose shell command is not a danger-claude call and gets no marker. The window therefore has to clear the longest timeout any project configures, on either key. Deriving it removes the pair of settings that had to stay coherent, and fixes the health card in the same move: it documents that "a long but live danger-claude run isn't flagged", which is false today for a project with a raised `dc_timeout`.

`HealthReport` runs under `test/rails_helper.rb`, which does **not** load `lib/autodev`'s tree — so the `post_completion_timeout` default must live in `lib/autodev/config.rb` (already required there), not on `PipelineMonitor::PostCompletion`.

**Files:**
- Modify: `lib/autodev/config.rb` (add `POST_COMPLETION_TIMEOUT` near `DEFAULTS`, around `:43-62`)
- Modify: `lib/autodev/pipeline_monitor/post_completion.rb:25`
- Modify: `app/services/autodev/health_report.rb:43` (constants), `:77-79` (`stuck_active_after`), `:159-166` (`check_stuck_issues`), plus new private helpers
- Test: `test/services/health_report_stuck_window_test.rb` (create)

**Interfaces:**
- Consumes: nothing from earlier tasks (independent of 1–3).
- Produces: `Config::POST_COMPLETION_TIMEOUT` (Integer, 300); `Autodev::HealthReport::HEARTBEAT_FACTOR` (Integer, 2); `HealthReport#stuck_active_after` → Integer, memoized, now derived. `DormantAudit#active_window` already delegates to it (Task 5 pins that).

- [ ] **Step 1: Write the failing test**

Create `test/services/health_report_stuck_window_test.rb`:

```ruby
# frozen_string_literal: true

require_relative '../rails_helper'

# How the stuck-issues window is sized (Autodev #50).
#
# The window must clear the longest a live worker can legitimately go quiet:
# one danger-claude call (dc_timeout, bounded per call by the DangerClaudeRunner
# heartbeat) or one post_completion command (post_completion_timeout, which gets
# no heartbeat — it is not a danger-claude call). Both are per-project, so the
# window is sized on the widest value in play, doubled for margin.
#
# Getting this wrong is not a monitoring nit: DormantAudit#active_window reads
# the same method and repositions rows by update_all, outside the concurrency
# lock that serialises IssueProcessJob.
class HealthReportStuckWindowTest < ActiveSupport::TestCase
  BASE = Autodev::HealthReport::STUCK_ACTIVE_AFTER # 7200
  CONFIG = { 'poll_interval' => 300 }.freeze

  def window(config: CONFIG)
    Autodev::HealthReport.new(config: config).stuck_active_after
  end

  def project(**attrs)
    Project.create!({ gitlab_path: 'group/proj', slug: 'group__proj' }.merge(attrs))
  end

  # 2 × the baked dc_timeout default (1800) is 3600, under the floor — so the
  # default configuration behaves exactly as it did before this change.
  test 'defaults to the baked floor' do
    assert_equal BASE, window
  end

  test 'derives from a project dc_timeout that exceeds the floor' do
    project(dc_timeout: 5400)

    assert_equal 10_800, window
  end

  test 'derives from a project post_completion_timeout' do
    project(post_completion: ['deploy.sh'], post_completion_timeout: 5400)

    assert_equal 10_800, window
  end

  # A project configured in YAML but not yet imported into the projects table is
  # still live config: IssueProcessJob falls back to it.
  test 'counts a YAML-only project' do
    config = CONFIG.merge('projects' => [{ 'path' => 'group/yaml', 'dc_timeout' => 5400 }])

    assert_equal 10_800, window(config: config)
  end

  test 'takes the widest value when several projects configure one' do
    project(dc_timeout: 3600)
    Project.create!(gitlab_path: 'group/other', slug: 'group__other', dc_timeout: 5400)

    assert_equal 10_800, window
  end

  # An explicit setting is a floor, not a ceiling: an operator can widen the
  # window but cannot configure it into incoherence with dc_timeout.
  test 'an explicit setting wider than the derived value wins' do
    config = CONFIG.merge('monitoring' => { 'stuck_active_after_seconds' => 20_000 })

    assert_equal 20_000, window(config: config)
  end

  test 'an explicit setting narrower than the derived value loses' do
    project(dc_timeout: 5400)
    config = CONFIG.merge('monitoring' => { 'stuck_active_after_seconds' => 3600 })

    assert_equal 10_800, window(config: config)
  end

  # The check reports the window it used, so the effective value is visible
  # rather than implicit when a derived floor overrode the setting.
  test 'the stuck_issues check reports the effective window' do
    project(dc_timeout: 5400)
    check = Autodev::HealthReport.new(config: CONFIG).check(:stuck_issues)[:checks][:stuck_issues]

    assert_equal 10_800, check[:meta][:window_seconds]
  end

  # The widened window is load-bearing, not cosmetic: a row silent for 3h with a
  # 4h window is a live worker, and must not be flagged.
  test 'a row silent for less than the derived window is not stuck' do
    project(dc_timeout: 5400) # window 10800s = 3h
    Issue.create!(project_path: 'group/proj', issue_iid: 700, status: 'implementing',
                  created_at: 4.hours.ago)

    check = Autodev::HealthReport.new(config: CONFIG).check(:stuck_issues)[:checks][:stuck_issues]

    assert_equal :ok, check[:status]
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise x ruby -- bundle exec rake test TEST=test/services/health_report_stuck_window_test.rb`

Expected: FAIL. `defaults to the baked floor` and the two explicit-setting tests pass already; the five derivation tests return `7200`, and `the stuck_issues check reports the effective window` fails on a missing `:window_seconds` key.

- [ ] **Step 3: Add the `post_completion_timeout` default to `Config`**

In `lib/autodev/config.rb`, immediately after the `DEFAULTS` hash (which ends at the `}.freeze` around line 62), add:

```ruby
  # Baked default for the per-project `post_completion_timeout`, in seconds.
  # Deliberately a standalone constant rather than a DEFAULTS key: it has no
  # global form (there is no `post_completion` outside a project). It lives here
  # because Autodev::HealthReport sizes the stuck-issues window on it (Autodev
  # #50) and must not have to load the PipelineMonitor tree to read it.
  POST_COMPLETION_TIMEOUT = 300
```

- [ ] **Step 4: Read it from the one place that used the literal**

In `lib/autodev/pipeline_monitor/post_completion.rb`, replace line 25:

```ruby
      timeout = (@project_config['post_completion_timeout'] || ::Config::POST_COMPLETION_TIMEOUT).to_i
```

- [ ] **Step 5: Derive the window in `HealthReport`**

In `app/services/autodev/health_report.rb`, after the `STUCK_ACTIVE_AFTER` line, add:

```ruby
    # A live worker's silence is bounded by one danger-claude call — the
    # DangerClaudeRunner heartbeat (Autodev #50) writes an activity row per call,
    # so no loop can go quiet for longer than its own timeout. The window only
    # has to clear that timeout; twice over, for loop overhead and margin.
    HEARTBEAT_FACTOR = 2
```

Replace `stuck_active_after`:

```ruby
    # Derived, not just configured (Autodev #50). DormantAudit#active_window
    # reads this too and repositions rows by update_all, outside the
    # concurrency lock that serialises IssueProcessJob — so a window narrower
    # than the longest configured timeout does not merely mis-report, it lets
    # the audit mutate a row a live worker still holds. Deriving it means the
    # two settings can no longer be configured into disagreement.
    def stuck_active_after
      @stuck_active_after ||= [configured_stuck_active_after,
                               HEARTBEAT_FACTOR * longest_worker_timeout].max
    end
```

Then in the `private` section, next to `poll_interval` / `poll_stale_factor`:

```ruby
    def configured_stuck_active_after
      (@config.dig('monitoring', 'stuck_active_after_seconds') || STUCK_ACTIVE_AFTER).to_i
    end

    # The longest a worker can legitimately go quiet: one danger-claude call
    # (dc_timeout) or one post_completion command (post_completion_timeout —
    # not a danger-claude call, so it gets no heartbeat and its silence equals
    # its timeout exactly). Both are per-project only, so the window is sized on
    # the widest value in play. The baked defaults are always in the max: a
    # project that overrides neither still runs with them.
    def longest_worker_timeout
      [::Config::DEFAULTS['dc_timeout'], ::Config::POST_COMPLETION_TIMEOUT,
       Project.maximum(:dc_timeout), Project.maximum(:post_completion_timeout),
       *yaml_project_timeouts].compact.map(&:to_i).max
    end

    # Projects configured in config.yml but not yet imported into the projects
    # table: still live config, since IssueProcessJob falls back to the YAML hash
    # for a project with no row.
    def yaml_project_timeouts
      Array(@config['projects']).flat_map do |project|
        next [] unless project.is_a?(Hash)

        [project['dc_timeout'], project['post_completion_timeout']]
      end
    end
```

Finally, report the window in `check_stuck_issues`:

```ruby
    def check_stuck_issues
      stuck = stuck_issues
      # window_seconds so the effective value is visible: it is derived, so a
      # narrower `monitoring.stuck_active_after_seconds` does not apply.
      meta = { count: stuck.size, window_seconds: stuck_active_after }
      return build(:ok, 'no stuck issues', meta) if stuck.empty?

      meta[:sample] = stuck.first(5).map { |i| "##{i.issue_iid}(#{i.status})" }.join(' ')
      build(:warn, "#{stuck.size} issue(s) stuck with no path forward", meta)
    end
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `mise x ruby -- bundle exec rake test TEST=test/services/health_report_stuck_window_test.rb`

Expected: PASS, 10 runs, 0 failures.

- [ ] **Step 7: Check the existing health-report and post-completion tests still pass**

Run: `mise x ruby -- bundle exec rake test TEST=test/services/health_report_test.rb`
Then: `mise x ruby -- bundle exec rake test TEST=test/config_test.rb`

Expected: PASS both, unchanged. `health_report_test.rb` asserts `meta[:count]` on its own (`:128`) rather than comparing the whole hash, so the added `window_seconds` key does not break it — if you find yourself editing an existing assertion here, stop and check why.

- [ ] **Step 8: RuboCop**

Run: `mise x ruby -- rubocop app/services/autodev/health_report.rb lib/autodev/config.rb lib/autodev/pipeline_monitor/post_completion.rb test/services/health_report_stuck_window_test.rb`

Expected: no offenses. `health_report.rb` already carries `# rubocop:disable Metrics/ClassLength` on the class, so the four added methods are covered.

- [ ] **Step 9: Commit**

```bash
git add app/services/autodev/health_report.rb lib/autodev/config.rb lib/autodev/pipeline_monitor/post_completion.rb test/services/health_report_stuck_window_test.rb
git commit -F - <<'MSG'
fix: size the stuck-issues window on the longest configured timeout (Autodev #50)

stuck_active_after was a flat 7200s while dc_timeout and post_completion_timeout
are per-project and unbounded above. The two had to stay coherent by hand, and
nothing said so: a project raising dc_timeout past the window would let
dispatch_dormant_audit reposition a row a live worker still holds — silently,
since the audit writes by update_all outside the job's concurrency lock and the
model runs with whiny_transitions: false.

The window is now max(configured, 2 × the widest configured timeout), counting
both keys across DB rows and not-yet-imported YAML projects.
post_completion_timeout is in the max because running_post_completion runs a
shell command, not danger-claude, so it gets no heartbeat and its silence equals
its timeout exactly.

Nothing changes at default settings — 2 × 1800 is under the 7200 floor — and the
same fix makes the health card honest: it documents that a long but live
danger-claude run is not flagged, which was false for a raised dc_timeout. An
explicit monitoring.stuck_active_after_seconds is now a floor rather than a
ceiling, so the effective value is reported as meta[:window_seconds].

The baked post_completion_timeout default moves from a literal in
post_completion.rb to Config::POST_COMPLETION_TIMEOUT, so the formula and the
runtime read the same number — and so HealthReport does not have to load the
PipelineMonitor tree to size a window.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
```

---

### Task 5: Pin the regression on the dormant audit

`DormantAudit#active_window` already delegates to `HealthReport#stuck_active_after`, so Task 4 fixed the behaviour. This task proves it from the audit's own side — the assertion the ticket asked for — and cross-references the invariant where a reader of `revive_stalled!` will look.

**Files:**
- Modify: `test/dormant_audit_selection_test.rb` (extend the active-arm section, around `:99-113`)
- Modify: `app/services/autodev/dormant_audit.rb:114-124` (comment on `active_arm` / `active_window`)

**Interfaces:**
- Consumes: `HealthReport#stuck_active_after` derived (Task 4).
- Produces: nothing.

- [ ] **Step 1: Write the failing test**

In `test/dormant_audit_selection_test.rb`, add to the active-arm section (after `test_a_checking_pipeline_row_is_never_a_candidate`):

```ruby
  # The window is derived from the longest configured timeout (Autodev #50), so
  # a project that raises dc_timeout widens it instead of letting the audit
  # reposition a row a live worker still holds. 5400s ⇒ a 10800s (3h) window.
  #
  # The Project row is created here rather than in setup because
  # DatabaseTestHelper only wipes issues + activity_events, and these tests are
  # not transactional — an escaped row would widen the window for every other
  # test in the process.
  def test_an_active_row_within_a_widened_window_is_not_a_candidate
    Project.create!(gitlab_path: 'group/project', slug: 'group__project', dc_timeout: 5400)
    issue = create_issue(status: 'implementing', created_at: 4.hours.ago)
    ActivityEvent.create!(issue_id: issue.id, kind: 'heartbeat', level: 'info',
                          payload_json: '{}', created_at: 150.minutes.ago)

    refute_includes candidate_iids, issue.issue_iid
  ensure
    Project.where(gitlab_path: 'group/project').delete_all
  end

  # Control for the test above: the same row, the same 2.5h silence, with no
  # project widening the window, IS dormant under the 2h default.
  def test_the_same_row_is_a_candidate_under_the_default_window
    issue = create_issue(status: 'implementing', created_at: 4.hours.ago)
    ActivityEvent.create!(issue_id: issue.id, kind: 'heartbeat', level: 'info',
                          payload_json: '{}', created_at: 150.minutes.ago)

    assert_includes candidate_iids, issue.issue_iid
  end
```

- [ ] **Step 2: Run it to verify the first test fails**

Run: `mise x ruby -- bundle exec rake test TEST=test/dormant_audit_selection_test.rb TESTOPTS="--name=/widened_window|default_window/"`

Expected: with Task 4 already merged, **both pass**. If you are running this task before Task 4, `test_an_active_row_within_a_widened_window_is_not_a_candidate` fails (the row is selected under the flat 7200s window) — that is the regression these tests pin. Either order is acceptable; note which you saw in the commit body.

- [ ] **Step 3: Cross-reference the invariant in `DormantAudit`**

In `app/services/autodev/dormant_audit.rb`, replace the comment above `pending_window` / `active_window`:

```ruby
    # Both windows belong to HealthReport, on purpose: the stuck-issues card and
    # this pass must see the same rows, or the card keeps flagging what nothing
    # recovers — the shape of #47.
    #
    # `active_window` is also the safety boundary of this pass (Autodev #50).
    # `revive` mutates by update_all, from the poll cycle, outside the
    # `limits_concurrency` that serialises IssueProcessJob — so the window must
    # exceed the longest a *live* worker can stay silent, or a row gets
    # repositioned under the job that holds it. Two things hold that up:
    # DangerClaudeRunner writes an activity row per danger-claude call, and
    # HealthReport#stuck_active_after is derived from the longest configured
    # timeout. Neither is optional; see
    # docs/superpowers/specs/2026-08-10-live-worker-silence-invariant-design.md.
```

- [ ] **Step 4: Run the whole file**

Run: `mise x ruby -- bundle exec rake test TEST=test/dormant_audit_selection_test.rb`

Expected: PASS, 0 failures.

- [ ] **Step 5: RuboCop**

Run: `mise x ruby -- rubocop app/services/autodev/dormant_audit.rb test/dormant_audit_selection_test.rb`

Expected: no offenses. The test class already carries `# rubocop:disable Metrics/ClassLength`.

- [ ] **Step 6: Commit**

```bash
git add app/services/autodev/dormant_audit.rb test/dormant_audit_selection_test.rb
git commit -F - <<'MSG'
test: pin the dormant audit against a widened window (Autodev #50)

active_window delegates to HealthReport, so the derivation already fixed the
selection — but nothing asserted it from the audit's side, which is where the
mutation happens. A project with dc_timeout 5400 gets a 3h window, and a row
silent for 2.5h stays out of the arm; the control test shows the same row IS
dormant under the 2h default, so the pair fails if the derivation is ever
reverted.

The Project row is created per test and removed in an ensure block: these tests
are not transactional and DatabaseTestHelper only wipes issues and
activity_events, so an escaped row would widen the window for the whole process.

The comment on active_window now states the invariant instead of leaving it to
be rediscovered: this pass writes outside the per-issue concurrency lock, so the
window is a safety boundary, not a monitoring threshold.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
```

---

### Task 6: Docs and full-suite verification

**Files:**
- Modify: `CHANGELOG.md` (`[Unreleased]`, line 3)
- Modify: `docs/observability.md:47` (the `stuck_issues` bullet)
- Modify: `docs/usage/autodev-technical-usage.md:150` (the "Issues bloquées" bullet)
- Modify: `docs/superpowers/specs/2026-08-07-dormant-rows-audit-design.md:94-95` (the flat-7200 statement)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Add the changelog entry**

In `CHANGELOG.md`, under `## [Unreleased]`, add:

```markdown
### Fixed

- **A ticket being worked on can no longer be repositioned under the worker handling it (Autodev #50).** `dispatch_dormant_audit`'s active arm treats "no `activity_events` row for `stuck_active_after` (2 h)" as "the worker died", and mutates by `update_all` from the poll cycle — outside the `limits_concurrency` that serialises `IssueProcessJob`. What kept that safe was an unwritten assumption that a live worker cannot stay silent that long, and it was already false: `PipelineFixer` emits `:pipeline_fixing` once on entering the state, then loops over the N failed jobs with **two** danger-claude calls each (prompt, then commit) and no activity event in between, so silence in `fixing_pipeline` reaches `N × 2 × dc_timeout` — 3 600 s per job at the default 1 800. Two slow jobs reach the window, three exceed it, and calls do hit their timeout in practice (the documented reason `dc_timeout` went from 600 to 1 800). Past the window the row was moved to `checking_pipeline` under the running fixer; in that state the outcome happens to coincide with the transition the worker was heading to, but a closure or an unassignment inside the window sent the row to `closed` / `done` while the worker kept pushing — an MR the row no longer records, with no error line, since the model runs `whiny_transitions: false`. Two changes close it. **(1)** Every danger-claude call now writes a liveness row (new `activity_events` kind `heartbeat`, DB-only — no GitLab round-trip) from `DangerClaudeRunner`, the single point both `danger_claude_prompt` and `danger_claude_commit` funnel through, so silence is bounded by one call in every loop, including ones not yet written. The rows are invisible to the UI (new `ActivityEvent.user_visible` scope, applied to the issue timeline and the dashboard sparkline, plus an SSE guard) and deliberately **counted** by `Issue.without_activity_since`, which is the whole mechanism. **(2)** `HealthReport#stuck_active_after` is now `max(configured, 2 × the longest configured timeout)` — over `dc_timeout` **and** `post_completion_timeout` (whose shell command gets no heartbeat, so its silence equals its timeout), across `projects` rows and not-yet-imported YAML entries — so raising a per-project timeout widens the window instead of breaking the invariant, and the two settings can no longer be configured into disagreement. Nothing changes at default settings (2 × 1 800 is under the 7 200 floor); an explicit `monitoring.stuck_active_after_seconds` becomes a floor rather than a ceiling, and the effective value is reported as `window_seconds` in the `stuck_issues` check. The same fix makes the "Issues bloquées" card honest — it documents that a long but live danger-claude run is not flagged, which was false for any project with a raised `dc_timeout`. The baked `post_completion_timeout` default moves out of a literal into `Config::POST_COMPLETION_TIMEOUT` so the formula and the runtime read one number. New tests: `activity_event_heartbeat_test.rb`, `danger_claude_runner_heartbeat_test.rb`, `controllers/issues_controller_heartbeat_test.rb`, `services/health_report_stuck_window_test.rb`, plus a widened-window regression pair in `dormant_audit_selection_test.rb` and a sparkline exclusion in `weekly_activity_counts_test.rb`.
```

- [ ] **Step 2: Update `docs/observability.md`**

In the `stuck_issues` bullet (line 47), replace the fragment `depuis \`monitoring.stuck_active_after_seconds\` (défaut 2 h)` with:

```
depuis la fenêtre d'inactivité — `max(monitoring.stuck_active_after_seconds ou 2 h, 2 × le plus long timeout configuré)`, pris sur `dc_timeout` **et** `post_completion_timeout` de tous les projets connus (Autodev #50). Cette fenêtre est aussi la borne de sûreté de `dispatch_dormant_audit`, qui mute les lignes hors du verrou de concurrence par ticket : elle doit dépasser le plus long silence qu'un worker *vivant* peut produire. C'est pourquoi un réglage explicite plus étroit est ignoré (la valeur effective est renvoyée dans `meta.window_seconds`) et pourquoi chaque appel danger-claude écrit un `ActivityEvent` `kind: 'heartbeat'` (DB uniquement, invisible dans l'UI) : sans lui, une boucle comme `PipelineFixer` — deux appels par job échoué, aucun événement entre les jobs — dépasse la fenêtre alors que le worker travaille toujours
```

- [ ] **Step 3: Update `docs/usage/autodev-technical-usage.md`**

In the "Issues bloquées" bullet (line 150), replace `sans \`ActivityEvent\` depuis \`monitoring.stuck_active_after_seconds\` (défaut 2 h)` with:

```
sans `ActivityEvent` depuis la fenêtre d'inactivité — `max(monitoring.stuck_active_after_seconds ou 2 h, 2 × le plus long `dc_timeout` / `post_completion_timeout` configuré)`, donc relever un timeout par projet élargit la fenêtre automatiquement (Autodev #50). Chaque appel danger-claude écrit un heartbeat en base (invisible dans l'UI) pour que la fenêtre mesure la vraie inactivité et pas la durée d'un run
```

- [ ] **Step 4: Correct the #47 spec's flat-window statement**

In `docs/superpowers/specs/2026-08-07-dormant-rows-audit-design.md`, replace the two lines that read `stuck_active_after` (`STUCK_ACTIVE_AFTER = 7200`, overridable via `monitoring.stuck_active_after_seconds`) for the active arm.` with:

```markdown
`stuck_active_after` for the active arm — a flat `STUCK_ACTIVE_AFTER = 7200` at
the time of this design, overridable via `monitoring.stuck_active_after_seconds`.
Autodev #50 later made it derived (`max(configured, 2 × the longest configured
dc_timeout / post_completion_timeout)`) and paired it with a per-call heartbeat,
because a live worker could already outlast the flat window — see
`2026-08-10-live-worker-silence-invariant-design.md`.
```

- [ ] **Step 5: Run the full suite**

Run: `mise x ruby -- bundle exec rake test`

Expected: 0 failures, 0 errors. Any failure here is a real regression from Tasks 1–5 — fix it before committing, and do not silence a test to make the suite green.

- [ ] **Step 6: RuboCop over the whole project**

Run: `mise x ruby -- rubocop`

Expected: no offenses.

- [ ] **Step 7: Commit**

```bash
git add CHANGELOG.md docs/observability.md docs/usage/autodev-technical-usage.md docs/superpowers/specs/2026-08-07-dormant-rows-audit-design.md
git commit -F - <<'MSG'
docs: record the live-worker silence invariant (Autodev #50)

The stuck-issues window is no longer a flat threshold an operator sets, so both
docs that described it as `monitoring.stuck_active_after_seconds (défaut 2 h)`
now state the derivation and, more importantly, why it exists: the window is
dispatch_dormant_audit's safety boundary, not a monitoring preference, because
that pass writes outside the per-issue concurrency lock.

The #47 spec asserted the flat 7200s as fact; it now carries the correction
inline rather than silently disagreeing with the code.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
```

---

## Verification

After Task 6, confirm all three of these before reporting the work done:

1. `mise x ruby -- bundle exec rake test` — 0 failures, 0 errors. Quote the counts.
2. `mise x ruby -- rubocop` — no offenses.
3. `git log --oneline master..HEAD` — six commits (Tasks 1–6) on top of the spec commit `5e93bb2`.

Then hand back for review: the branch is `fix/50-worker-silence-invariant`, merged into `master` by the operator (the repo's convention is a merge commit per `fix/*` branch, e.g. `143fc5a`), and Skynet #50 gets its progress note.
