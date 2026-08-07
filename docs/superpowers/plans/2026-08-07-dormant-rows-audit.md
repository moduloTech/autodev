# Dormant-rows audit Implementation Plan (Autodev #47 + #48)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every autodev issue row that has stopped moving one bounded second look, which either closes it, marks it unassigned, or puts it back on a path the poller walks.

**Architecture:** A single new dispatch pass, `dispatch_dormant_audit`, replaces `dispatch_error_recheck` (#34). It selects three populations of dormant rows (orphaned `pending`, spent-budget `error`, worker-pruned active states) behind one bounded counter, performs one GitLab read per candidate, and routes on the answer to `close_externally` / `stop_unassigned` / re-arm. Two extractions stop the bug from recurring: `Issue.without_activity_since` becomes the single definition of "stuck" shared with `HealthReport`, and `Issue.revive_stalled!` becomes the single rule for unsticking a row, shared with `Issue.recover_on_startup!`.

**Tech Stack:** Ruby 3.2+, Rails 8.1.3, ActiveRecord + SQLite (WAL), AASM, Solid Queue, Minitest, RuboCop.

**Spec:** [`docs/superpowers/specs/2026-08-07-dormant-rows-audit-design.md`](../specs/2026-08-07-dormant-rows-audit-design.md)

## Global Constraints

- **TDD.** Every task writes the failing test first, watches it fail, then implements. No exceptions.
- **RuboCop green.** Run `mise x ruby -- rubocop` before every commit. **Never edit any `.rubocop.yml`** — the linter config is maintained separately.
- **CHANGELOG.** `CHANGELOG.md`'s `[Unreleased]` section is updated in the same pass (Task 7 carries the entry for the whole feature).
- **Conventional Commits.** `<type>: <description>` plus a body explaining the why. Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`.
- **i18n.** Every user-facing string goes through `Locales.t` / `t_web`, and every new key exists in **both** `fr` and `en` with identical `%{var}` placeholders. Never write a literal user-facing string.
- **Test commands.** Full suite: `bundle exec rake test`. One file: `bundle exec rake test TEST=test/<file>_test.rb`. One test: `bundle exec rake test TEST=test/<file>_test.rb TESTOPTS="-n /<pattern>/"`.
- **Comment style.** This codebase documents *why*, not *what*, in prose above the method. Match it: every new method that encodes a decision gets a comment naming the ticket and the failure it prevents.
- **Timestamps in SQL.** `next_retry_at` is a **string** column; `error_recheck_at` / `infra_recheck_at` are **datetime**. Existing code compares both with SQLite's `datetime('now')`. Keep that idiom.

---

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `db/migrate/20260807000001_rename_error_recheck_to_dormant_recheck.rb` | Column rename, reversible |
| `app/services/autodev/external_state.rb` | `Autodev::ExternalState` — the GitLab-truth decisions (`closed?` / `assigned_to_autodev?`) and their two write outcomes (`close_externally`, `stop_unassigned`), shared by the two passes that need them |
| `app/services/autodev/dormant_audit.rb` | `Autodev::DormantAudit` — selection of the three arms, bounded counter, routing, cap exhaustion |
| `test/dormant_audit_selection_test.rb` | The three arms' candidate queries and their bounds |
| `test/dormant_audit_routing_test.rb` | The three outcomes + cap exhaustion + GitLab error resilience |
| `test/models/issue_dormancy_test.rb` | `Issue.without_activity_since` |
| `test/models/revive_stalled_test.rb` | `Issue.revive_stalled!` per state, through both call sites |

**Modified:**

| File | Change |
|---|---|
| `app/models/issue.rb` | `without_activity_since` scope, `revive_stalled!`, `recover_on_startup!` delegates to it |
| `app/services/autodev/health_report.rb:158-173` | `stuck_issues` rewritten on the shared scope |
| `app/services/autodev/poll_dispatcher.rb` | `dispatch_error_recheck` and its 5 helpers removed; `dispatch_dormant_audit` delegates to `DormantAudit`; `ExternalState` included |
| `test/error_recheck_dispatch_test.rb` | Deleted — its cases move into the two new test files (Task 5) |
| `config/locales/web.{fr,en}.yml` | `web_errors_explain_attention_dormant_exhausted` |
| `config/locales/activity.{fr,en}.yml` | `activity_dormant_exhausted` |
| `CHANGELOG.md`, `CLAUDE.md` | Task 7 |

**Why `ExternalState` is its own module:** `#48`'s finding is that `dispatch_unassignment` and the dormant audit ask GitLab the *same question*. If each pass keeps its own copy of "is it closed / is it still ours / what do we write when it isn't", they will drift — which is exactly how #44's scope decision turned into a bug. One module, two includers.

**Why `DormantAudit` is its own class:** `poll_dispatcher.rb` is already 424 lines under a `Metrics/ClassLength` disable. The pass adds ~90 lines with its own selection, bookkeeping and routing — a separate service keeps both files readable, and it matches how `PipelineMonitor` already delegates to `lib/autodev/pipeline_monitor/*.rb`.

---

### Task 1: Rename the recheck columns to `dormant_recheck_*`

Pure rename, no behaviour change. Doing it first means every later task writes the final names once.

**Files:**
- Create: `db/migrate/20260807000001_rename_error_recheck_to_dormant_recheck.rb`
- Modify: `app/services/autodev/poll_dispatcher.rb:23-28` (constants), `:327-372` (query + helpers)
- Test: `test/error_recheck_dispatch_test.rb` (updated in place; deleted later in Task 5)

**Interfaces:**
- Consumes: nothing.
- Produces: columns `issues.dormant_recheck_count` (integer, `null: false, default: 0`) and `issues.dormant_recheck_at` (datetime). Constants `Autodev::PollDispatcher::DEFAULT_DORMANT_AUDIT_MAX = 3` and `DEFAULT_DORMANT_AUDIT_BACKOFF = 3600`. Config keys `dormant_audit_max` / `dormant_audit_backoff`, each falling back to the legacy `error_recheck_max` / `error_recheck_backoff`.

- [ ] **Step 1: Write the failing test for the legacy config fallback**

Add to `test/error_recheck_dispatch_test.rb`, and update the two existing tests that name the old columns (`test_excludes_when_the_cap_is_reached` → `dormant_recheck_count:`, `test_excludes_when_the_backoff_is_still_running` → `dormant_recheck_at:`, `test_selects_once_the_backoff_has_elapsed` → both, `test_rearming_costs_one_attempt_and_backs_off` → both, `test_declining_still_costs_an_attempt` → `dormant_recheck_count`):

```ruby
  # A production config.yml already tuned for #34 must keep working after the
  # rename — the operator set a policy, not a column name.
  def test_the_legacy_error_recheck_max_key_still_applies
    issue = spent(dormant_recheck_count: 2)

    refute_includes candidate_iids(config: CONFIG.merge('error_recheck_max' => 2)), issue.issue_iid
  end

  def test_the_new_key_wins_over_the_legacy_one
    issue = spent(dormant_recheck_count: 2)

    assert_includes candidate_iids(config: CONFIG.merge('error_recheck_max' => 2,
                                                        'dormant_audit_max' => 5)),
                    issue.issue_iid
  end
```

- [ ] **Step 2: Run the file to verify it fails**

Run: `bundle exec rake test TEST=test/error_recheck_dispatch_test.rb`
Expected: FAIL — `unknown attribute 'dormant_recheck_count' for Issue`.

- [ ] **Step 3: Write the migration**

```ruby
# frozen_string_literal: true

# Widens the bounded second-chance bookkeeping from `error` rows only (#34) to
# every dormant row — orphaned `pending` (#47) and worker-pruned active states
# included. The columns change name, not meaning: they already carried "how many
# bounded second chances this row has been granted, and when the next one is
# due". Renaming keeps a single counter per row instead of two counters with
# overlapping semantics.
#
# `column_exists?`-guarded so it is a no-op on a DB that was already migrated —
# `config/initializers/auto_migrate.rb` runs this on every boot.
class RenameErrorRecheckToDormantRecheck < ActiveRecord::Migration[8.1]
  def up
    rename_column :issues, :error_recheck_count, :dormant_recheck_count if column_exists?(:issues, :error_recheck_count)
    rename_column :issues, :error_recheck_at, :dormant_recheck_at if column_exists?(:issues, :error_recheck_at)
  end

  def down
    rename_column :issues, :dormant_recheck_count, :error_recheck_count if column_exists?(:issues, :dormant_recheck_count)
    rename_column :issues, :dormant_recheck_at, :error_recheck_at if column_exists?(:issues, :dormant_recheck_at)
  end
end
```

- [ ] **Step 4: Rename the constants and config readers in `PollDispatcher`**

Replace lines 23-28:

```ruby
    # Bounds of the second-chance recovery for a dormant row
    # (`dispatch_dormant_audit`, Autodev #34 then #47/#48): at most 3 extra
    # rounds per ticket, spaced an hour apart, so a transient failure gets
    # another shot once its cause clears while a real code failure just burns
    # the cap.
    DEFAULT_DORMANT_AUDIT_MAX = 3
    DEFAULT_DORMANT_AUDIT_BACKOFF = 3600
```

Replace the two readers at lines 364-372:

```ruby
    # `error_recheck_*` are the pre-#47 names of these knobs. A production
    # config.yml tuned for #34 expressed a policy, not a column name, so it
    # keeps working.
    def dormant_audit_max
      (@project_config['dormant_audit_max'] || @config['dormant_audit_max'] ||
        @project_config['error_recheck_max'] || @config['error_recheck_max'] ||
        DEFAULT_DORMANT_AUDIT_MAX).to_i
    end

    def dormant_audit_backoff
      (@project_config['dormant_audit_backoff'] || @config['dormant_audit_backoff'] ||
        @project_config['error_recheck_backoff'] || @config['error_recheck_backoff'] ||
        DEFAULT_DORMANT_AUDIT_BACKOFF).to_i
    end
```

Then update the three call sites inside `fetch_error_recheck_candidates`, `recheck_errored` and `log_error_recheck` to use `dormant_recheck_count` / `dormant_recheck_at` / `dormant_audit_max` / `dormant_audit_backoff`.

- [ ] **Step 5: Run the file to verify it passes**

Run: `bundle exec rake test TEST=test/error_recheck_dispatch_test.rb`
Expected: PASS, all tests.

- [ ] **Step 6: Run the full suite and RuboCop**

Run: `bundle exec rake test && mise x ruby -- rubocop`
Expected: no failures, no offenses.

- [ ] **Step 7: Commit**

```bash
git add db/migrate/20260807000001_rename_error_recheck_to_dormant_recheck.rb \
        app/services/autodev/poll_dispatcher.rb test/error_recheck_dispatch_test.rb
git commit -m "refactor: rename error_recheck_* to dormant_recheck_* (Autodev #47)

The bounded second-chance bookkeeping stops being error-specific: #47 and #48
widen it to orphaned pending rows and worker-pruned active states. The columns
already meant 'how many bounded second chances this row has had', so this is a
rename, not a semantic change.

Config keys follow (dormant_audit_max / dormant_audit_backoff) with a
read-through fallback on the legacy names, so a production config.yml already
tuned for #34 keeps working."
```

---

### Task 2: `Issue.without_activity_since` — one definition of "stuck"

**Files:**
- Modify: `app/models/issue.rb`, `app/services/autodev/health_report.rb:158-173`
- Test: `test/models/issue_dormancy_test.rb` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: `Issue.without_activity_since(cutoff)` — an `ActiveRecord::Relation` scope returning rows whose most recent `activity_events` row is older than `cutoff`, falling back to `issues.created_at` for rows that never emitted one. Chainable after any other `Issue` scope.

- [ ] **Step 1: Write the failing test**

Create `test/models/issue_dormancy_test.rb`:

```ruby
# frozen_string_literal: true

require_relative '../rails_helper'

# `Issue.without_activity_since` — the single definition of "this row has
# stopped moving", shared by HealthReport's stuck-issues card and by
# `dispatch_dormant_audit` (Autodev #47).
#
# They must not drift: the whole shape of #47 was a card that correctly flagged
# 14 frozen rows while no pass did anything about them. One scope, two readers.
class IssueDormancyTest < ActiveSupport::TestCase
  def issue(overrides = {})
    Issue.create!({ project_path: 'group/proj', issue_iid: rand(10_000..99_999),
                    status: 'pending' }.merge(overrides))
  end

  def event(issue, at)
    ActivityEvent.create!(issue_id: issue.id, kind: 'transition', level: 'info',
                          payload_json: '{}', created_at: at)
  end

  def dormant_ids(cutoff = 1.hour.ago) = Issue.without_activity_since(cutoff).pluck(:id)

  # --- the fallback for rows that never emitted anything ------------

  def test_an_old_row_with_no_activity_is_dormant
    old = issue(created_at: 3.hours.ago)

    assert_includes dormant_ids, old.id
  end

  def test_a_fresh_row_with_no_activity_is_not_dormant
    fresh = issue(created_at: 1.minute.ago)

    assert_not_includes dormant_ids, fresh.id
  end

  # --- rows that have emitted --------------------------------------

  def test_a_row_whose_last_event_is_old_is_dormant
    row = issue(created_at: 3.hours.ago)
    event(row, 2.hours.ago)

    assert_includes dormant_ids, row.id
  end

  def test_a_row_with_a_recent_event_is_not_dormant
    row = issue(created_at: 3.hours.ago)
    event(row, 2.hours.ago)
    event(row, 1.minute.ago)

    assert_not_includes dormant_ids, row.id
  end

  # --- the NULL trap ------------------------------------------------

  # activity_events carries issue-less rows (kind 'poller', 'usage'). A naive
  # `WHERE id NOT IN (SELECT issue_id ...)` returns the empty set as soon as one
  # NULL is in the subquery — SQL three-valued logic. This test is the guard.
  def test_issueless_events_do_not_swallow_the_result
    old = issue(created_at: 3.hours.ago)
    ActivityEvent.create!(issue_id: nil, kind: 'poller', level: 'info',
                          payload_json: '{}', created_at: 1.minute.ago)

    assert_includes dormant_ids, old.id
  end

  # --- chainability -------------------------------------------------

  def test_it_chains_after_another_scope
    old = issue(created_at: 3.hours.ago)
    issue(created_at: 3.hours.ago, status: 'error')

    assert_equal [old.id], Issue.where(status: 'pending').without_activity_since(1.hour.ago).pluck(:id)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rake test TEST=test/models/issue_dormancy_test.rb`
Expected: FAIL with `undefined method 'without_activity_since'`.

- [ ] **Step 3: Write the scope**

Add to `app/models/issue.rb`, near the other class-level query helpers:

```ruby
  # A row that has stopped moving: no activity_events entry since `cutoff`,
  # falling back to its own created_at when it never emitted one.
  #
  # Single source of truth for two readers that must never disagree —
  # HealthReport's stuck-issues card and `dispatch_dormant_audit` (Autodev #47).
  # A card that flags what no pass acts on is how 14 rows sat frozen since April.
  #
  # `issue_id: nil` is excluded from the subquery on purpose: activity_events
  # also holds issue-less rows ('poller', 'usage'), and a single NULL inside a
  # `NOT IN` makes SQL return the empty set for every row.
  #
  # The subquery is bounded by the outer relation's ids, not by the time window
  # alone: no activity_events index leads with `created_at`, so a `created_at`-only
  # bound cannot seek and SQLite scans the whole table — 0.79s per call on an
  # 800k-row DB against ~1ms here, on an endpoint /healthz may poll constantly.
  # `idx_ae_issue (issue_id, created_at)` makes the bounded form an indexed seek.
  scope :without_activity_since, lambda { |cutoff|
    recent = ActivityEvent.where.not(issue_id: nil)
                          .where(issue_id: all.select(:id))
                          .where(created_at: cutoff..)
                          .select(:issue_id)
    where.not(id: recent).where(created_at: ...cutoff)
  }
```

The `where(issue_id: all.select(:id))` bound is load-bearing, not decoration:
without it this scope violates the `/healthz` constraint listed above. Verify with
`EXPLAIN QUERY PLAN` that the query seeks rather than scans.

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rake test TEST=test/models/issue_dormancy_test.rb`
Expected: PASS.

- [ ] **Step 5: Rewrite `HealthReport#stuck_issues` on the scope**

Replace `app/services/autodev/health_report.rb:158-173` (`stuck_issues` and `stuck?`) with:

```ruby
    # Two windows, one definition of dormancy (Issue.without_activity_since,
    # Autodev #47). `pending` should leave within a poll cycle so it reuses the
    # poller-staleness window; the active workflow states tolerate long
    # danger-claude runs, which still emit activity, so they get a wider one.
    def stuck_issues
      Issue.where(status: PENDING_STUCK_STATES).without_activity_since(@now - poll_stale_after).to_a +
        Issue.where(status: ACTIVE_STUCK_STATES).without_activity_since(@now - stuck_active_after).to_a
    end
```

- [ ] **Step 6: Run the health report tests to verify no behaviour change**

Run: `bundle exec rake test TEST=test/services/health_report_test.rb`
Expected: PASS, unchanged.

- [ ] **Step 7: Run the full suite and RuboCop**

Run: `bundle exec rake test && mise x ruby -- rubocop`
Expected: no failures, no offenses.

- [ ] **Step 8: Commit**

```bash
git add app/models/issue.rb app/services/autodev/health_report.rb test/models/issue_dormancy_test.rb
git commit -m "refactor: extract Issue.without_activity_since (Autodev #47)

HealthReport's stuck-issues card and the incoming dormant-rows audit must
agree on what 'stopped moving' means, or the card keeps flagging rows no pass
recovers — the exact shape of #47. One scope, two readers.

The subquery excludes issue_id NULL rows ('poller', 'usage' events): a single
NULL inside NOT IN collapses the result set to empty."
```

---

### Task 3: `Issue.revive_stalled!` — one rule for unsticking a row

**Files:**
- Modify: `app/models/issue.rb:234-308`
- Test: `test/models/revive_stalled_test.rb` (create)

**Interfaces:**
- Consumes: `Issue.reset_for_retry!(scope, reset_budget:, clear_attention:)` (existing).
- Produces: `Issue.revive_stalled!(scope)` → Integer, the number of rows touched. Constants `Issue::REVIVE_TO_PENDING` (`RECOVERABLE_ACTIVE_STATES + %w[answering_question]`), `Issue::REVIVE_TO_PIPELINE` (`%w[reviewing fixing_pipeline fixing_discussions]`), `Issue::REVIVE_TO_DONE` (`%w[running_post_completion]`), and `Issue::STALLED_STATES` (the union).

- [ ] **Step 1: Write the failing test**

Create `test/models/revive_stalled_test.rb`:

```ruby
# frozen_string_literal: true

require_relative '../rails_helper'

# `Issue.revive_stalled!` — the single rule for putting a frozen active row back
# on a path the poller walks (Autodev #47).
#
# Two call sites need it and they must not disagree: `recover_on_startup!` (a
# worker died and the service restarted) and `dispatch_dormant_audit` (a worker
# was pruned and the service did NOT restart — FailedJobReaper discards the job
# and no pass re-dispatches those states).
#
# The rules are deliberately not uniform. `running_post_completion` carries an
# MR but must finish as `done`: the hook is non-fatal and must not be replayed.
# Re-deriving that per call site is how you get a row redoing a review round.
class ReviveStalledTest < ActiveSupport::TestCase
  def stalled(status, overrides = {})
    Issue.create!({ project_path: 'group/proj', issue_iid: rand(10_000..99_999),
                    status: status }.merge(overrides))
  end

  def revive!(issue)
    Issue.revive_stalled!(Issue.where(id: issue.id))
    issue.reload
  end

  # --- pre-MR states restart as pending, and must be discoverable ----

  def test_a_pre_mr_implementing_row_restarts_as_pending
    issue = revive!(stalled('implementing', mr_iid: nil))

    assert_equal 'pending', issue.status
  end

  # Without the stamp, fetch_retryable skips it and dispatch_new_issues never
  # sees it either (the label is still label_doing) — #26's orphan pattern.
  def test_a_pre_mr_row_is_stamped
    issue = revive!(stalled('implementing', mr_iid: nil))

    assert_not_nil issue.next_retry_at
  end

  def test_answering_question_restarts_as_pending
    issue = revive!(stalled('answering_question', mr_iid: nil))

    assert_equal 'pending', issue.status
  end

  # --- post-MR states resume at checking_pipeline --------------------

  def test_a_row_with_an_mr_resumes_at_checking_pipeline
    issue = revive!(stalled('implementing', mr_iid: 42))

    assert_equal 'checking_pipeline', issue.status
  end

  def test_reviewing_resumes_at_checking_pipeline
    issue = revive!(stalled('reviewing', mr_iid: 42))

    assert_equal 'checking_pipeline', issue.status
  end

  def test_fixing_pipeline_resumes_at_checking_pipeline
    issue = revive!(stalled('fixing_pipeline', mr_iid: 42))

    assert_equal 'checking_pipeline', issue.status
  end

  # PipelineMonitor re-derives whether unresolved discussions remain, so
  # checking_pipeline is the state that decides rather than assumes.
  def test_fixing_discussions_resumes_at_checking_pipeline
    issue = revive!(stalled('fixing_discussions', mr_iid: 42))

    assert_equal 'checking_pipeline', issue.status
  end

  # --- the exception that justifies the extraction -------------------

  # It carries an MR, so the naive rule would send it to checking_pipeline and
  # make it redo a whole review round. The hook is non-fatal: it ends as done.
  def test_running_post_completion_ends_as_done_not_checking_pipeline
    issue = revive!(stalled('running_post_completion', mr_iid: 42))

    assert_equal 'done', issue.status
  end

  def test_running_post_completion_is_stamped_finished
    issue = revive!(stalled('running_post_completion', mr_iid: 42))

    assert_not_nil issue.finished_at
  end

  # --- untouched states ---------------------------------------------

  def test_a_checking_pipeline_row_is_left_alone
    issue = revive!(stalled('checking_pipeline', mr_iid: 42))

    assert_equal 'checking_pipeline', issue.status
  end

  def test_a_done_row_is_left_alone
    issue = revive!(stalled('done'))

    assert_equal 'done', issue.status
  end

  # --- the other call site goes through it ---------------------------

  def test_startup_recovery_revives_fixing_discussions
    issue = stalled('fixing_discussions', mr_iid: 42)

    Issue.recover_on_startup!(max_retries: 1)

    assert_equal 'checking_pipeline', issue.reload.status
  end

  def test_startup_recovery_revives_answering_question
    issue = stalled('answering_question', mr_iid: nil)

    Issue.recover_on_startup!(max_retries: 1)

    assert_equal 'pending', issue.reload.status
  end

  def test_startup_recovery_still_ends_post_completion_as_done
    issue = stalled('running_post_completion', mr_iid: 42)

    Issue.recover_on_startup!(max_retries: 1)

    assert_equal 'done', issue.reload.status
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rake test TEST=test/models/revive_stalled_test.rb`
Expected: FAIL with `undefined method 'revive_stalled!'`.

- [ ] **Step 3: Write `revive_stalled!` and rewire `recover_on_startup!`**

In `app/models/issue.rb`, replace `recover_on_startup!` (lines 234-240) and the four `recover_*` helpers it composed for active states (`recover_fixing_pipeline!`, `recover_reviewing!`, `recover_post_completion!`, `recover_stuck_processing!`, lines 287-308) with:

```ruby
  def self.recover_on_startup!(max_retries:)
    recover_errored!(max_retries) + revive_stalled!(where(status: STALLED_STATES))
  end

  RECOVERABLE_ACTIVE_STATES = %w[cloning checking_spec implementing committing pushing creating_mr].freeze

  # How each stalled state gets back onto a path the poller walks. The rules are
  # not uniform, which is the whole reason this lives in one place:
  #
  # - pre-MR work restarts as `pending` **with a stamp** (`reset_for_retry!`
  #   owns that split — see its comment; without the stamp the row is orphaned
  #   because the GitLab label is still `label_doing`);
  # - post-MR work resumes at `checking_pipeline`, which `dispatch_pipelines`
  #   polls unconditionally and where `PipelineMonitor` re-derives what is left
  #   to do — including whether discussions remain;
  # - `running_post_completion` carries an MR yet must end as `done`: the hook
  #   is non-fatal and is deliberately not replayed.
  #
  # Two call sites: `recover_on_startup!` (a worker died and the service
  # restarted) and `dispatch_dormant_audit` (a worker was pruned and the service
  # did *not* restart — Autodev #47). `answering_question` and
  # `fixing_discussions` are new here: HealthReport monitors them, but boot
  # recovery had no rule for either, so a row frozen in one survived a restart.
  REVIVE_TO_PENDING = (RECOVERABLE_ACTIVE_STATES + %w[answering_question]).freeze
  REVIVE_TO_PIPELINE = %w[reviewing fixing_pipeline fixing_discussions].freeze
  REVIVE_TO_DONE = %w[running_post_completion].freeze
  STALLED_STATES = (REVIVE_TO_PENDING + REVIVE_TO_PIPELINE + REVIVE_TO_DONE).freeze

  def self.revive_stalled!(scope)
    reset_for_retry!(scope.where(status: REVIVE_TO_PENDING)) +
      scope.where(status: REVIVE_TO_PIPELINE).update_all(status: 'checking_pipeline', started_at: nil) +
      scope.where(status: REVIVE_TO_DONE).update_all(status: 'done', finished_at: Time.current)
  end
```

Note: `reset_for_retry!` already performs the pre-MR / post-MR split internally, so a `REVIVE_TO_PENDING` row that *does* carry an MR correctly lands in `checking_pipeline` rather than restarting from scratch.

- [ ] **Step 4: Point `HealthReport::ACTIVE_STUCK_STATES` at the new constant**

`HealthReport::ACTIVE_STUCK_STATES` (`app/services/autodev/health_report.rb:39-41`) lists exactly the states `STALLED_STATES` now names. Two hand-maintained copies of the same list is how the next state gets added to one and not the other, so replace the literal with:

```ruby
    # The states a stalled row can be revived out of — the same set
    # `Issue.revive_stalled!` knows the rules for, by construction. A state this
    # card flags but nothing can revive would be a card nobody can act on.
    ACTIVE_STUCK_STATES = ::Issue::STALLED_STATES
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bundle exec rake test TEST=test/models/revive_stalled_test.rb && bundle exec rake test TEST=test/services/health_report_test.rb`
Expected: PASS.

- [ ] **Step 6: Run the neighbouring model tests**

Run: `bundle exec rake test TEST=test/models/reset_for_retry_test.rb && bundle exec rake test TEST=test/models/issue_recovery_test.rb`
Expected: PASS. If `issue_recovery_test.rb` asserts on the removed `recover_reviewing!` / `recover_fixing_pipeline!` / `recover_post_completion!` / `recover_stuck_processing!` methods by name, rewrite those assertions to go through `revive_stalled!` — the behaviour they check is preserved, the entry point moved.

- [ ] **Step 7: Run the full suite and RuboCop**

Run: `bundle exec rake test && mise x ruby -- rubocop`
Expected: no failures, no offenses.

- [ ] **Step 8: Commit**

```bash
git add app/models/issue.rb app/services/autodev/health_report.rb \
        test/models/revive_stalled_test.rb test/models/issue_recovery_test.rb
git commit -m "refactor: extract Issue.revive_stalled! (Autodev #47)

Boot recovery and the incoming dormant-rows audit both need to unstick a
frozen active row, and the rules are not uniform: running_post_completion
carries an MR but must end as done, because the hook is non-fatal and must not
be replayed. Re-deriving that per call site is how a row ends up redoing a
review round.

Also closes two gaps this made visible: HealthReport monitors
fixing_discussions and answering_question, but recover_on_startup! had no rule
for either, so a row frozen in one survived a restart untouched."
```

---

### Task 4: `Autodev::ExternalState` — the shared GitLab-truth decisions

**Files:**
- Create: `app/services/autodev/external_state.rb`
- Modify: `app/services/autodev/poll_dispatcher.rb:209-253`
- Test: `test/closed_on_gitlab_dispatch_test.rb` (must stay green untouched)

**Interfaces:**
- Consumes: `GitlabHelpers.field`, `GitlabHelpers.current_user_id`, `ActivityLogger.post`.
- Produces: module `Autodev::ExternalState`, expecting the includer to expose `@client`, `@path` and `@logger`. Public methods: `externally_closed?(gl_issue) → Boolean`, `assigned_to_autodev?(gl_issue) → Boolean`, `close_externally(issue) → void`, `stop_unassigned(issue) → void`.

- [ ] **Step 1: Write the failing test**

Create `test/external_state_test.rb`:

```ruby
# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/activity_logger'

# `Autodev::ExternalState` — what GitLab says about a ticket, and the two writes
# that follow when the answer is "not ours anymore" (Autodev #48).
#
# Both `dispatch_unassignment` and `dispatch_dormant_audit` ask GitLab the same
# question and must reach the same conclusion. #48 exists because that logic
# lived in one pass and the other population was simply never swept; a shared
# module is what keeps the two from drifting again.
class ExternalStateTest < Minitest::Test
  include DatabaseTestHelper

  AUTODEV_ID = 7

  FakeUser = Struct.new(:id)
  FakeAssignee = Struct.new(:id)
  FakeIssue = Struct.new(:state, :assignees)

  class StubClient
    def user = FakeUser.new(AUTODEV_ID)
  end

  class Host
    include Autodev::ExternalState

    def initialize(client, logger)
      @client = client
      @path = 'group/project'
      @logger = logger
    end
  end

  def setup
    setup_database
    GitlabHelpers.instance_variable_set(:@current_user_id, AUTODEV_ID)
    @host = Host.new(StubClient.new, StubLogger.new)
  end

  def gl(state: 'opened', assignee_ids: [AUTODEV_ID])
    FakeIssue.new(state, assignee_ids.map { |id| FakeAssignee.new(id) })
  end

  # --- reading GitLab's answer --------------------------------------

  def test_a_closed_ticket_reads_as_closed
    assert @host.externally_closed?(gl(state: 'closed'))
  end

  def test_an_open_ticket_does_not
    refute @host.externally_closed?(gl)
  end

  def test_an_assigned_ticket_reads_as_ours
    assert @host.assigned_to_autodev?(gl)
  end

  def test_a_ticket_assigned_to_someone_else_does_not
    refute @host.assigned_to_autodev?(gl(assignee_ids: [999]))
  end

  # --- the writes ---------------------------------------------------

  # `close` is valid from pending and error too, which is what lets the dormant
  # audit reuse this untouched (#48).
  def test_closing_works_from_pending
    issue = create_issue(status: 'pending')
    @host.close_externally(issue)

    assert_equal 'closed', issue.reload.status
  end

  def test_closing_works_from_error
    issue = create_issue(status: 'error')
    @host.close_externally(issue)

    assert_equal 'closed', issue.reload.status
  end

  def test_closing_stamps_finished_at_and_clears_attention
    issue = create_issue(status: 'error', needs_attention: true, attention_reason: 'stagnation_pipeline')
    @host.close_externally(issue)
    issue.reload

    refute_nil issue.finished_at
    refute issue.needs_attention
    assert_nil issue.attention_reason
  end

  # The failure message survives the close: /errors stops listing the row, but
  # /issues/:id still shows why it failed.
  def test_closing_keeps_the_error_message
    issue = create_issue(status: 'error', error_message: 'boom')
    @host.close_externally(issue)

    assert_equal 'boom', issue.reload.error_message
  end

  def test_stopping_an_unassigned_row_moves_it_to_done
    issue = create_issue(status: 'pending')
    @host.stop_unassigned(issue)
    issue.reload

    assert_equal 'done', issue.status
    refute_nil issue.finished_at
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rake test TEST=test/external_state_test.rb`
Expected: FAIL with `uninitialized constant Autodev::ExternalState`.

- [ ] **Step 3: Write the module**

Create `app/services/autodev/external_state.rb`:

```ruby
# frozen_string_literal: true

module Autodev
  # What GitLab says about a ticket, and the two writes that follow when the
  # answer is "not ours anymore".
  #
  # Two passes need this and must never disagree: `dispatch_unassignment`
  # sweeps active rows every cycle (Autodev #44), and `dispatch_dormant_audit`
  # sweeps dormant ones behind a backoff (#47/#48). #48 exists precisely because
  # this decision lived in one pass while the other population was never swept —
  # so it lives in one module now, with two includers.
  #
  # The includer must expose `@client`, `@path` and `@logger`.
  module ExternalState
    def externally_closed?(gl_issue)
      ::GitlabHelpers.field(gl_issue, :state) == 'closed'
    end

    def assigned_to_autodev?(gl_issue)
      (::GitlabHelpers.field(gl_issue, :assignees) || [])
        .any? { |a| ::GitlabHelpers.field(a, :id) == ::GitlabHelpers.current_user_id(@client) }
    end

    # Mirrors IssuesController#close_issue!, minus the audit actor: nobody
    # clicked anything, the ticket just went away on GitLab. `error_message` is
    # deliberately preserved — /errors stops listing the row, /issues/:id still
    # explains why it failed.
    def close_externally(issue)
      return unless issue.may_close?

      @logger.info("Issue ##{issue.issue_iid}: closed on GitLab, closing locally", project: @path)
      issue.close!
      ::Issue.where(id: issue.id).update_all(finished_at: Time.current, needs_attention: false,
                                             attention_reason: nil, attention_detail: nil)
      ::ActivityLogger.post(::ActivityLogger::Ctx.new(@client, @path, @logger),
                            issue, :closed_externally)
    end

    def stop_unassigned(issue)
      @logger.info("Issue ##{issue.issue_iid}: no longer assigned, transitioning to done",
                   project: @path)
      issue.update(status: 'done', finished_at: Time.current)
      ::ActivityLogger.post(::ActivityLogger::Ctx.new(@client, @path, @logger),
                            issue, :unassigned_stop)
    end
  end
end
```

- [ ] **Step 4: Make `PollDispatcher` include it**

In `app/services/autodev/poll_dispatcher.rb`, add `include ExternalState` under the class declaration, delete the now-duplicated private `close_externally`, `stop_unassigned` and `assigned_to_autodev?` definitions (lines 236-253 and 279-282), and rewrite `check_external_state` to use the predicate:

```ruby
    def check_external_state(issue)
      gl_issue = @client.issue(@path, issue.issue_iid)
      return close_externally(issue) if externally_closed?(gl_issue)
      return if assigned_to_autodev?(gl_issue)

      stop_unassigned(issue)
    rescue ::Gitlab::Error::ResponseError => e
      @logger.error("Failed to check external state for ##{issue.issue_iid}: #{e.message}",
                    project: @path)
    end
```

- [ ] **Step 5: Run both test files to verify they pass**

Run: `bundle exec rake test TEST=test/external_state_test.rb && bundle exec rake test TEST=test/closed_on_gitlab_dispatch_test.rb`
Expected: PASS. `closed_on_gitlab_dispatch_test.rb` must pass **without edits** — it is the non-regression proof for the extraction.

- [ ] **Step 6: Run the full suite and RuboCop**

Run: `bundle exec rake test && mise x ruby -- rubocop`
Expected: no failures, no offenses.

- [ ] **Step 7: Commit**

```bash
git add app/services/autodev/external_state.rb app/services/autodev/poll_dispatcher.rb test/external_state_test.rb
git commit -m "refactor: extract Autodev::ExternalState (Autodev #48)

dispatch_unassignment and the incoming dormant-rows audit ask GitLab the same
question — state + assignees — and must reach the same conclusion. #48 exists
because that decision lived in one pass while pending and error rows were
never swept at all; sharing the module is what stops the two from drifting
again.

Pure extraction: closed_on_gitlab_dispatch_test.rb passes unedited."
```

---

### Task 5: `Autodev::DormantAudit` — selection, routing, and the pass

The heart of the feature. Selection and routing land together because a candidate query with no consumer cannot be judged.

**Files:**
- Create: `app/services/autodev/dormant_audit.rb`
- Modify: `app/services/autodev/poll_dispatcher.rb` (remove `dispatch_error_recheck` + its 4 helpers, add `dispatch_dormant_audit`)
- Test: `test/dormant_audit_selection_test.rb`, `test/dormant_audit_routing_test.rb` (create)
- Delete: `test/error_recheck_dispatch_test.rb` (its cases live on in the two new files)

**Interfaces:**
- Consumes: `Issue.without_activity_since` (Task 2), `Issue.revive_stalled!` and `Issue::STALLED_STATES` (Task 3), `Autodev::ExternalState` (Task 4), `PollDispatcher#dormant_audit_max` / `#dormant_audit_backoff` (Task 1).
- Produces: `Autodev::DormantAudit.new(client:, path:, config:, project_config:, logger:, now: Time.current)` with `#run → Integer` (candidates audited) and, for tests, `#candidates → Array<Issue>`. `PollDispatcher#dispatch_dormant_audit` calls it.

- [ ] **Step 1: Write the failing selection test**

Create `test/dormant_audit_selection_test.rb`:

```ruby
# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'

# Which rows the dormant audit picks up (Autodev #47 + #48).
#
# Three populations, one bound. A `pending` row with next_retry_at NULL is
# invisible to dispatch_new_issues (it carries label_doing, not labels_todo)
# AND to dispatch_retries (which requires the stamp) — that is #47, 14 rows
# frozen on powerpanne/core, the oldest since April 13th. An `error` row with a
# spent budget is #34's population, unchanged. An active row with no activity
# for 2h is a pruned worker: FailedJobReaper discards the job and no pass
# re-dispatches those states.
class DormantAuditSelectionTest < Minitest::Test
  include DatabaseTestHelper

  PROJECT_CONFIG = { 'path' => 'group/project', 'max_retries' => 1 }.freeze
  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example',
             'poll_interval' => 300 }.freeze

  class StubClient; end

  def setup
    setup_database
    @logger = StubLogger.new
  end

  def audit(config: CONFIG, project_config: PROJECT_CONFIG)
    Autodev::DormantAudit.new(client: StubClient.new, path: project_config['path'],
                              config: config, project_config: project_config, logger: @logger)
  end

  def candidate_iids(**) = audit(**).candidates.map(&:issue_iid)

  # The pending window is HealthReport's poller-staleness one:
  # max(poll_interval * 3, 900) = 900s here. Two hours is safely past it.
  def orphan(overrides = {})
    create_issue({ status: 'pending', next_retry_at: nil,
                   created_at: 2.hours.ago }.merge(overrides))
  end

  def spent(overrides = {})
    create_issue({ status: 'error', retry_count: 2, created_at: 2.hours.ago }.merge(overrides))
  end

  def frozen_active(overrides = {})
    create_issue({ status: 'implementing', created_at: 4.hours.ago }.merge(overrides))
  end

  # --- the pending arm (#47) ----------------------------------------

  def test_an_orphaned_pending_row_is_a_candidate
    issue = orphan

    assert_includes candidate_iids, issue.issue_iid
  end

  # It already has a path forward: dispatch_retries picks it up on the stamp.
  def test_a_stamped_pending_row_is_not
    issue = orphan(next_retry_at: 1.hour.ago)

    refute_includes candidate_iids, issue.issue_iid
  end

  # find_or_create_issue creates the row with next_retry_at NULL and enqueues
  # :process right after. Auditing it in that gap would burn a bounded attempt
  # on a ticket that never had its chance.
  def test_a_freshly_created_pending_row_is_not
    issue = orphan(created_at: 1.minute.ago)

    refute_includes candidate_iids, issue.issue_iid
  end

  def test_a_pending_row_with_recent_activity_is_not
    issue = orphan
    ActivityEvent.create!(issue_id: issue.id, kind: 'transition', level: 'info',
                          payload_json: '{}', created_at: 1.minute.ago)

    refute_includes candidate_iids, issue.issue_iid
  end

  # --- the error arm (#34, unchanged) -------------------------------

  def test_a_spent_budget_error_row_is_a_candidate
    issue = spent

    assert_includes candidate_iids, issue.issue_iid
  end

  # Still inside its budget: dispatch_retries owns it. Picking it up here too
  # would double-dispatch the same ticket.
  def test_an_error_row_still_within_budget_is_not
    issue = spent(retry_count: 1)

    refute_includes candidate_iids, issue.issue_iid
  end

  # --- the active arm (#47, the FailedJobReaper gap) ----------------

  def test_an_active_row_frozen_for_hours_is_a_candidate
    issue = frozen_active

    assert_includes candidate_iids, issue.issue_iid
  end

  def test_an_active_row_still_emitting_activity_is_not
    issue = frozen_active
    ActivityEvent.create!(issue_id: issue.id, kind: 'danger_claude', level: 'info',
                          payload_json: '{}', created_at: 10.minutes.ago)

    refute_includes candidate_iids, issue.issue_iid
  end

  # checking_pipeline waits on an external pipeline and is re-polled every
  # cycle — the documented "no blocked state". It is not stalled.
  def test_a_checking_pipeline_row_is_never_a_candidate
    issue = create_issue(status: 'checking_pipeline', mr_iid: 42, created_at: 4.hours.ago)

    refute_includes candidate_iids, issue.issue_iid
  end

  def test_a_done_row_is_never_a_candidate
    issue = create_issue(status: 'done', created_at: 4.hours.ago)

    refute_includes candidate_iids, issue.issue_iid
  end

  # --- the shared bound ---------------------------------------------

  def test_a_row_at_the_cap_is_excluded
    issue = orphan(dormant_recheck_count: Autodev::PollDispatcher::DEFAULT_DORMANT_AUDIT_MAX)

    refute_includes candidate_iids, issue.issue_iid
  end

  def test_a_row_inside_its_backoff_is_excluded
    issue = orphan(dormant_recheck_count: 1, dormant_recheck_at: 1.hour.from_now)

    refute_includes candidate_iids, issue.issue_iid
  end

  def test_a_row_whose_backoff_elapsed_is_included
    issue = orphan(dormant_recheck_count: 1, dormant_recheck_at: 1.hour.ago)

    assert_includes candidate_iids, issue.issue_iid
  end

  def test_the_cap_is_configurable
    issue = orphan(dormant_recheck_count: 2)

    refute_includes candidate_iids(config: CONFIG.merge('dormant_audit_max' => 2)), issue.issue_iid
  end

  # A production config.yml tuned for #34 expressed a policy, not a column name.
  def test_the_legacy_error_recheck_key_still_applies
    issue = orphan(dormant_recheck_count: 2)

    refute_includes candidate_iids(config: CONFIG.merge('error_recheck_max' => 2)), issue.issue_iid
  end

  # --- scoping ------------------------------------------------------

  def test_another_project_is_not_swept
    issue = orphan(project_path: 'other/project')

    refute_includes candidate_iids, issue.issue_iid
  end

  # --- the invariant #47 is really about -----------------------------

  # The stuck-issues card flagged all 14 frozen rows correctly and nothing acted
  # on them. Anything that card reports, in this project and under cap, must be
  # a candidate here — otherwise the two drift apart again and the card goes
  # back to being a report nobody can act on.
  def test_everything_healthreport_calls_stuck_is_a_candidate
    orphan
    create_issue(status: 'implementing', created_at: 4.hours.ago)
    flagged = Autodev::HealthReport.new(config: CONFIG).send(:stuck_issues)
              .select { |i| i.project_path == PROJECT_CONFIG['path'] }

    assert_predicate flagged, :any?, 'fixture must produce at least one stuck row'
    assert_empty flagged.map(&:issue_iid) - candidate_iids
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rake test TEST=test/dormant_audit_selection_test.rb`
Expected: FAIL with `uninitialized constant Autodev::DormantAudit`.

- [ ] **Step 3: Write the selection half of `DormantAudit`**

Create `app/services/autodev/dormant_audit.rb`:

```ruby
# frozen_string_literal: true

module Autodev
  # One bounded second look at every row that has stopped moving
  # (Autodev #47 + #48).
  #
  # #47: a `pending` row whose `next_retry_at` is NULL is invisible to
  # `dispatch_new_issues` (it carries `label_doing`, so it is absent from the
  # `labels_todo` query) and to `dispatch_retries` (which requires the stamp).
  # 14 such rows sat frozen on powerpanne/core, the oldest since April 13th.
  #
  # #48: `dispatch_unassignment` only sweeps active rows, on the assumption that
  # a row always eventually moves. A dormant row never does — so a ticket closed
  # or reassigned while parked in `pending`/`error` was never noticed. That
  # matters most precisely when re-arming exists: the closure has to be seen
  # *before* the row restarts, which here is a `return`, not a pass ordering.
  #
  # This class does NOT reimplement the retry mechanics. It repositions state
  # and lets `dispatch_retries` — which runs immediately after — do the work,
  # labels and activity log included. Replaces `dispatch_error_recheck` (#34),
  # whose `error` population is now one of three arms.
  class DormantAudit
    include ExternalState

    def initialize(client:, path:, config:, project_config:, logger:, now: Time.current)
      @client = client
      @path = path
      @config = config
      @project_config = project_config
      @logger = logger
      @now = now
    end

    # Rows to audit this cycle: dormant, under cap, past backoff. Materialised
    # before any write, because the routing mutates `dormant_recheck_*` and the
    # status — both of which the queries filter on.
    def candidates
      dormant_rows.select { |issue| under_cap?(issue) && backoff_elapsed?(issue) }
    end

    private

    # The three arms, before the bound is applied. Kept separate from
    # `candidates` because Task 6 needs the same three populations *past* the
    # cap. The set is small by construction, so filtering in Ruby is clearer
    # than three more SQL predicates.
    def dormant_rows
      pending_arm.to_a + error_arm.to_a + active_arm.to_a
    end

    def base = ::Issue.where(project_path: @path)

    # The bound that keeps a forgotten ticket from making us call GitLab on
    # every poll forever.
    def under_cap?(issue) = (issue.dormant_recheck_count || 0) < cap

    def backoff_elapsed?(issue) = issue.dormant_recheck_at.nil? || issue.dormant_recheck_at <= @now

    # The age threshold is load-bearing: `find_or_create_issue` creates a row
    # with `next_retry_at` NULL and enqueues `:process` right after, so without
    # it every freshly discovered ticket would be audited in that gap.
    def pending_arm
      base.where(status: 'pending', next_retry_at: nil)
          .without_activity_since(@now - pending_window)
    end

    def error_arm
      base.where(status: 'error')
          .where('retry_count > ?', ::Config.max_retries(@project_config, @config))
    end

    def active_arm
      base.where(status: ::Issue::STALLED_STATES)
          .without_activity_since(@now - active_window)
    end

    # Both windows belong to HealthReport, on purpose: the stuck-issues card and
    # this pass must see the same rows, or the card keeps flagging what nothing
    # recovers — the shape of #47.
    def pending_window = health_report.poll_stale_after

    def active_window = health_report.stuck_active_after

    def health_report = @health_report ||= HealthReport.new(config: @config, now: @now)

    # `error_recheck_*` are the pre-#47 names of these knobs. A production
    # config.yml tuned for #34 expressed a policy, not a column name, so it
    # keeps working.
    def cap
      (@project_config['dormant_audit_max'] || @config['dormant_audit_max'] ||
        @project_config['error_recheck_max'] || @config['error_recheck_max'] ||
        PollDispatcher::DEFAULT_DORMANT_AUDIT_MAX).to_i
    end

    def backoff
      (@project_config['dormant_audit_backoff'] || @config['dormant_audit_backoff'] ||
        @project_config['error_recheck_backoff'] || @config['error_recheck_backoff'] ||
        PollDispatcher::DEFAULT_DORMANT_AUDIT_BACKOFF).to_i
    end
  end
end
```

Two support changes this needs:

1. In `app/services/autodev/health_report.rb`, promote `poll_stale_after` and `stuck_active_after` from `private` to public readers (move them above the `private` keyword), noting in their comment that `DormantAudit` reads them too. They are already pure computations over config.
2. Delete `dormant_audit_max` / `dormant_audit_backoff` from `PollDispatcher` — Task 1 put them there so the rename stayed self-contained; they now live on `DormantAudit` as `cap` / `backoff`. `DEFAULT_DORMANT_AUDIT_MAX` and `DEFAULT_DORMANT_AUDIT_BACKOFF` stay on `PollDispatcher`, where the existing `DEFAULT_*` pass constants live.

- [ ] **Step 4: Run the selection test to verify it passes**

Run: `bundle exec rake test TEST=test/dormant_audit_selection_test.rb`
Expected: PASS.

- [ ] **Step 5: Write the failing routing test**

Create `test/dormant_audit_routing_test.rb`:

```ruby
# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/activity_logger'

# What the dormant audit does with GitLab's answer (Autodev #47 + #48).
#
# One read, three outcomes. Closure wins over unassignment (a closed ticket is
# closed whether or not it is still assigned), and both win over re-arming —
# which is the whole point of #48 landing with #47 rather than after it: the two
# real cases found on 2026-08-06 were a ticket closed on GitLab (#16207) and one
# handed back to a human (#15909), both still sitting in `pending`. Re-arming
# either would have restarted work that is no longer ours.
class DormantAuditRoutingTest < Minitest::Test
  include DatabaseTestHelper

  PROJECT_CONFIG = { 'path' => 'group/project', 'max_retries' => 1 }.freeze
  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example',
             'poll_interval' => 300 }.freeze
  AUTODEV_ID = 7

  FakeUser = Struct.new(:id)
  FakeAssignee = Struct.new(:id)
  FakeIssue = Struct.new(:state, :assignees)

  class StubClient
    attr_reader :calls

    def initialize(state: 'opened', assignee_ids: [AUTODEV_ID])
      @state = state
      @assignee_ids = assignee_ids
      @calls = 0
    end

    def user = FakeUser.new(AUTODEV_ID)

    def issue(_project, _iid)
      @calls += 1
      FakeIssue.new(@state, @assignee_ids.map { |id| FakeAssignee.new(id) })
    end
  end

  def setup
    setup_database
    @logger = StubLogger.new
    GitlabHelpers.instance_variable_set(:@current_user_id, AUTODEV_ID)
  end

  def run_audit(issue, client: StubClient.new, config: CONFIG)
    Autodev::DormantAudit.new(client: client, path: PROJECT_CONFIG['path'], config: config,
                              project_config: PROJECT_CONFIG, logger: @logger).run
    issue.reload
  end

  def orphan(overrides = {})
    create_issue({ status: 'pending', next_retry_at: nil, created_at: 2.hours.ago }.merge(overrides))
  end

  def spent(overrides = {})
    create_issue({ status: 'error', retry_count: 2, created_at: 2.hours.ago }.merge(overrides))
  end

  # --- outcome 1: closed on GitLab (#16207) -------------------------

  def test_a_closed_pending_row_is_closed_locally
    issue = run_audit(orphan, client: StubClient.new(state: 'closed'))

    assert_equal 'closed', issue.status
  end

  def test_a_closed_error_row_is_closed_locally
    issue = run_audit(spent, client: StubClient.new(state: 'closed'))

    assert_equal 'closed', issue.status
  end

  def test_a_closed_row_is_not_rearmed
    issue = run_audit(spent, client: StubClient.new(state: 'closed'))

    assert_equal 2, issue.retry_count
  end

  # Closure wins: `closed` says more than `done`.
  def test_a_closed_and_unassigned_row_is_closed_not_done
    issue = run_audit(orphan, client: StubClient.new(state: 'closed', assignee_ids: [999]))

    assert_equal 'closed', issue.status
  end

  # --- outcome 2: handed back to a human (#15909) -------------------

  def test_an_unassigned_pending_row_goes_to_done
    issue = run_audit(orphan, client: StubClient.new(assignee_ids: [999]))

    assert_equal 'done', issue.status
  end

  def test_an_unassigned_row_is_not_rearmed
    issue = run_audit(spent, client: StubClient.new(assignee_ids: [999]))

    assert_equal 2, issue.retry_count
  end

  # --- outcome 3: still ours -----------------------------------------

  def test_an_orphaned_pending_row_gets_a_due_stamp
    issue = run_audit(orphan)

    assert_equal 'pending', issue.status
    refute_nil issue.next_retry_at
    assert_operator issue.next_retry_at, :<=, Time.current
  end

  def test_a_spent_error_row_gets_its_budget_back
    issue = run_audit(spent)

    assert_equal 0, issue.retry_count
    refute_nil issue.next_retry_at
  end

  # A pruned worker left it mid-implementation; revive_stalled! owns the rules.
  def test_a_frozen_pre_mr_active_row_restarts_as_pending
    issue = run_audit(create_issue(status: 'implementing', mr_iid: nil, created_at: 4.hours.ago))

    assert_equal 'pending', issue.status
    refute_nil issue.next_retry_at
  end

  def test_a_frozen_post_mr_active_row_resumes_at_checking_pipeline
    issue = run_audit(create_issue(status: 'implementing', mr_iid: 42, created_at: 4.hours.ago))

    assert_equal 'checking_pipeline', issue.status
  end

  # --- the bound ------------------------------------------------------

  def test_auditing_costs_one_attempt_and_backs_off
    issue = run_audit(orphan)

    assert_equal 1, issue.dormant_recheck_count
    assert_operator issue.dormant_recheck_at, :>, Time.current
  end

  # Declining costs an attempt too, or a forgotten ticket makes us call GitLab
  # on every single poll forever.
  def test_declining_still_costs_an_attempt
    issue = run_audit(spent, client: StubClient.new(state: 'closed'))

    assert_equal 1, issue.dormant_recheck_count
  end

  def test_one_gitlab_read_per_candidate
    client = StubClient.new
    orphan
    Autodev::DormantAudit.new(client: client, path: PROJECT_CONFIG['path'], config: CONFIG,
                              project_config: PROJECT_CONFIG, logger: @logger).run

    assert_equal 1, client.calls
  end

  # --- resilience -----------------------------------------------------

  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  class FailingClient < StubClient
    def issue(_project, _iid)
      raise Gitlab::Error::ResponseError,
            FakeResponse.new('boom', 500, FakeRequest.new('https://gitlab.example', '/api/v4/issues'))
    end
  end

  def test_a_gitlab_error_leaves_the_status_untouched
    issue = run_audit(orphan, client: FailingClient.new)

    assert_equal 'pending', issue.status
  end

  # The counter is bumped before the read on purpose: an unreachable project
  # burns the cap instead of being retried on every cycle forever.
  def test_a_gitlab_error_still_costs_an_attempt
    issue = run_audit(orphan, client: FailingClient.new)

    assert_equal 1, issue.dormant_recheck_count
  end
end
```

- [ ] **Step 6: Run test to verify it fails**

Run: `bundle exec rake test TEST=test/dormant_audit_routing_test.rb`
Expected: FAIL with `undefined method 'run'`.

- [ ] **Step 7: Write the routing half**

Add to `Autodev::DormantAudit`, `#run` public and the rest private:

```ruby
    # Returns the number of candidates audited.
    def run
      candidates.each { |issue| audit(issue) }.size
    end
```

```ruby
    # The counter is bumped *before* the GitLab read: an unreachable project
    # must burn the cap rather than be retried on every cycle forever. Every
    # candidate costs one bounded attempt whether or not it ends up re-armed.
    def audit(issue)
      attempt = (issue.dormant_recheck_count || 0) + 1
      issue.update(dormant_recheck_count: attempt, dormant_recheck_at: backoff.seconds.from_now)
      route(issue, @client.issue(@path, issue.issue_iid), attempt)
    rescue ::Gitlab::Error::ResponseError => e
      @logger.error("Failed to audit dormant ##{issue.issue_iid}: #{e.message}", project: @path)
    end

    # Closure wins over unassignment (a closed ticket is closed whether or not
    # it is still assigned), and both win over re-arming — a ticket that went
    # away or was handed to a human is not ours to restart. That ordering is the
    # substance of #48 and it is a `return`, not a pass ordering.
    #
    # All three outcomes resolve the row: it leaves the arms either terminally
    # (`closed` / `done`) or with a path forward. There is no "declined" outcome
    # here, unlike #34's pass — see Task 6 for where a row can still die quietly.
    def route(issue, gl_issue, attempt)
      if externally_closed?(gl_issue)
        log_outcome(issue, attempt, 'closed on GitLab')
        close_externally(issue)
      elsif !assigned_to_autodev?(gl_issue)
        log_outcome(issue, attempt, 'unassigned')
        stop_unassigned(issue)
      else
        log_outcome(issue, attempt, 'revived')
        revive(issue)
      end
    end

    def log_outcome(issue, attempt, verb)
      @logger.info("Dormant audit #{attempt}/#{cap} for issue ##{issue.issue_iid}: #{verb}",
                   project: @path)
    end

    # Never reimplements the retry mechanics: it repositions the row and lets
    # `dispatch_retries`, which runs immediately after, take it through the
    # usual `:retry_errored` / `:retry_stuck` path — labels and activity log
    # included.
    def revive(issue)
      return ::Issue.revive_stalled!(::Issue.where(id: issue.id)) if ::Issue::STALLED_STATES.include?(issue.status)

      issue.update(retry_count: 0, next_retry_at: Time.current)
    end
```

- [ ] **Step 8: Run the routing test to verify it passes**

Run: `bundle exec rake test TEST=test/dormant_audit_routing_test.rb`
Expected: PASS.

- [ ] **Step 9: Wire the pass into `PollDispatcher` and delete the old one**

In `app/services/autodev/poll_dispatcher.rb`: rename the call in `dispatch_existing` from `dispatch_error_recheck` to `dispatch_dormant_audit` (same position — immediately before `dispatch_retries`, so a budget re-armed this cycle is picked up by it), delete `dispatch_error_recheck`, `fetch_error_recheck_candidates`, `recheck_errored`, `worth_rearming?` and `log_error_recheck` along with their comment block, and add:

```ruby
    # === bounded second look at every row that has stopped moving ===
    #
    # Replaces `dispatch_error_recheck` (#34), whose `error` population is now
    # one of three arms. See Autodev::DormantAudit for the why.
    def dispatch_dormant_audit
      DormantAudit.new(client: @client, path: @path, config: @config,
                       project_config: @project_config, logger: @logger).run
    end
```

Then delete the superseded test file:

```bash
git rm test/error_recheck_dispatch_test.rb
```

- [ ] **Step 10: Run the full suite and RuboCop**

Run: `bundle exec rake test && mise x ruby -- rubocop`
Expected: no failures, no offenses. If `test/usage_gate_dispatch_test.rb` names `dispatch_error_recheck`, update it to `dispatch_dormant_audit` — the pass keeps running during a quota outage (it never reaches danger-claude), so its assertion is unchanged in substance.

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "fix: audit dormant rows instead of leaving them frozen (Autodev #47, #48)

A pending row with next_retry_at NULL was invisible to dispatch_new_issues (it
carries label_doing, so it is absent from the labels_todo query) and to
dispatch_retries (which requires the stamp). 14 such rows sat frozen on
powerpanne/core, the oldest since April 13th — 13 still open and still assigned
to autodev, i.e. real requested work never done.

dispatch_dormant_audit replaces dispatch_error_recheck and sweeps three
populations behind one bounded counter: orphaned pending rows, spent-budget
error rows, and active rows frozen by a pruned worker (FailedJobReaper discards
the job and no pass re-dispatches those states). One GitLab read per candidate
routes to close_externally, stop_unassigned, or a re-arm.

That routing also fixes #48: closure and unassignment on dormant rows were
never seen, because dispatch_unassignment only sweeps active states on the
assumption that a row always eventually moves. Here the closure check is the
first branch, so it is seen before any re-arm rather than after."
```

---

### Task 6: Surface a row that exhausts its cap

**Files:**
- Modify: `app/services/autodev/dormant_audit.rb`, `config/locales/activity.{fr,en}.yml`, `config/locales/web.{fr,en}.yml`
- Test: `test/dormant_audit_routing_test.rb` (extend)

**Interfaces:**
- Consumes: `ActivityLogger.warn_event(issue, key, **vars)` — writes a warn-level `activity_events` row and updates **no** GitLab note.
- Produces: rows stamped `needs_attention: true, attention_reason: 'dormant_exhausted'`; i18n keys `activity_dormant_exhausted` and `web_errors_explain_attention_dormant_exhausted`.

- [ ] **Step 1: Write the failing test**

Append to `test/dormant_audit_routing_test.rb`:

```ruby
  # --- end of cap -----------------------------------------------------

  # #34's pass went silent when its cap ran out: the row became permanently
  # immobile with no signal anywhere. That is #47's own complaint — "real,
  # requested work, never done, with no signal" — so the pass replacing it must
  # not inherit it.
  #
  # The moment to signal is NOT a refused attempt: every routing outcome
  # resolves the row (closed, done, or given a path). A row dies quietly the
  # other way — it gets revived, falls dormant again, and after `cap` rounds it
  # simply stops being selected. So the condition is "at cap AND still dormant",
  # which needs no GitLab read at all.
  CAP = Autodev::PollDispatcher::DEFAULT_DORMANT_AUDIT_MAX

  def test_a_row_at_the_cap_and_still_dormant_is_flagged
    issue = run_audit(spent(dormant_recheck_count: CAP))

    assert issue.needs_attention
    assert_equal 'dormant_exhausted', issue.attention_reason
  end

  def test_an_orphaned_pending_row_at_the_cap_is_flagged
    issue = run_audit(orphan(dormant_recheck_count: CAP))

    assert issue.needs_attention
  end

  def test_a_row_under_the_cap_is_not_flagged
    issue = run_audit(spent(dormant_recheck_count: CAP - 1))

    refute issue.needs_attention
  end

  # It was just revived: it has a path forward and is no longer dormant, so it
  # never enters the exhausted set even at the cap.
  def test_a_revived_row_is_not_flagged
    issue = run_audit(spent(dormant_recheck_count: CAP - 1))

    assert_equal 0, issue.retry_count
    refute issue.needs_attention
  end

  # Flagging must not rewrite the same signal on every single cycle.
  def test_an_already_flagged_row_is_not_reflagged
    at_cap = spent(dormant_recheck_count: CAP, needs_attention: true,
                   attention_reason: 'dormant_exhausted')
    run_audit(at_cap)

    assert_equal 1, ActivityEvent.where(issue_id: at_cap.id, level: 'warn').count
  end

  # The row is past the cap: it is not a candidate, so it costs nothing.
  def test_flagging_costs_no_gitlab_read
    client = StubClient.new
    spent(dormant_recheck_count: CAP)
    Autodev::DormantAudit.new(client: client, path: PROJECT_CONFIG['path'], config: CONFIG,
                              project_config: PROJECT_CONFIG, logger: @logger).run

    assert_equal 0, client.calls
  end

  def test_exhaustion_writes_a_warn_activity_event
    issue = run_audit(spent(dormant_recheck_count: CAP))
    event = ActivityEvent.where(issue_id: issue.id, level: 'warn').last

    refute_nil event
    assert_includes event.payload_json, 'dormant_exhausted'
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rake test TEST=test/dormant_audit_routing_test.rb TESTOPTS="-n /cap|exhaust|flag/"`
Expected: FAIL — `needs_attention` is false.

- [ ] **Step 3: Add the i18n keys**

`config/locales/activity.fr.yml`:

```yaml
  activity_dormant_exhausted: ":mag: Aucune reprise possible apres %{cap} verifications, demande laissee en l'etat"
```

`config/locales/activity.en.yml`:

```yaml
  activity_dormant_exhausted: ":mag: No restart possible after %{cap} checks, request left as is"
```

`config/locales/web.fr.yml`:

```yaml
  web_errors_explain_attention_dormant_exhausted: La demande ne progresse plus et les vérifications automatiques n'ont pas permis de la relancer. Elle reste en l'état — vérifiez sur GitLab si elle est toujours d'actualité.
```

`config/locales/web.en.yml`:

```yaml
  web_errors_explain_attention_dormant_exhausted: The request stopped progressing and the automatic checks could not restart it. It is left as is — check on GitLab whether it is still relevant.
```

Note the `activity_*` values avoid accented characters, matching the surrounding entries in those two files.

- [ ] **Step 4: Implement the exhaustion sweep in `DormantAudit`**

Extend `#run` and add the two methods below. `exhausted` reuses `dormant_rows`,
so the "still dormant" condition is by construction the same one the three arms
define — a row that was revived, closed or unassigned has already left the set:

```ruby
    # Returns the number of candidates audited.
    def run
      flag_exhausted!
      candidates.each { |issue| audit(issue) }.size
    end
```

```ruby
    # A row that reached the cap and is *still* dormant is one nothing will look
    # at again — the silent death #34's pass had and #47 complains about. Flagged
    # once, with no GitLab read: past the cap it is not a candidate.
    #
    # Nothing is posted to GitLab. The signal is for the operator (/errors, the
    # /admin/health card), not the requester: a row usually gets here by falling
    # dormant in a loop, and a comment would land on a ticket someone is already
    # handling.
    def flag_exhausted!
      dormant_rows.reject { |issue| under_cap?(issue) }
                  .reject(&:needs_attention)
                  .each { |issue| exhaust!(issue) }
    end

    def exhaust!(issue)
      ::Issue.where(id: issue.id).update_all(
        needs_attention: true, attention_reason: 'dormant_exhausted',
        attention_detail: "no restart after #{cap} dormant audits"
      )
      ::ActivityLogger.warn_event(issue, :dormant_exhausted, cap: cap)
      @logger.warn("Issue ##{issue.issue_iid}: dormant after #{cap} audits, giving up",
                   project: @path)
    end
```

`flag_exhausted!` runs **before** `candidates`, so a row cannot be audited and
flagged in the same cycle — the two sets are disjoint by the cap, and running
the flag first keeps that obvious rather than incidental.

- [ ] **Step 5: Run the routing test to verify it passes**

Run: `bundle exec rake test TEST=test/dormant_audit_routing_test.rb`
Expected: PASS, whole file.

- [ ] **Step 6: Verify the web copy renders**

Run: `bundle exec rake test TEST=test/locales_test.rb && bundle exec rake test TEST=test/errors_test.rb`
Expected: PASS. `locales_test.rb` checks fr/en key parity — if it fails, a key is missing on one side.

- [ ] **Step 7: Run the full suite and RuboCop**

Run: `bundle exec rake test && mise x ruby -- rubocop`
Expected: no failures, no offenses.

- [ ] **Step 8: Commit**

```bash
git add app/services/autodev/dormant_audit.rb config/locales test/dormant_audit_routing_test.rb
git commit -m "feat: flag a row that exhausts its dormant-audit cap (Autodev #47)

#34's pass went silent when its cap ran out — the row became permanently
immobile with no signal anywhere. That is the very complaint #47 makes about
the 14 frozen rows, so the pass replacing it must not reproduce it.

The signal is not tied to a refused attempt: every routing outcome resolves the
row. A row dies quietly the other way — revived, dormant again, and after cap
rounds it simply stops being selected. So a row at the cap that is still
dormant is stamped needs_attention with reason dormant_exhausted, which
surfaces it on /errors, on the /admin/health card and on the dashboard. No
GitLab read is involved, and nothing is posted to the ticket: a row usually
gets here by looping, and a comment would land on a ticket someone is already
handling."
```

---

### Task 7: Changelog and architecture docs

**Files:**
- Modify: `CHANGELOG.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing code-facing.

- [ ] **Step 1: Add the `[Unreleased]` changelog entry**

Under `## [Unreleased]`, in the existing `### Fixed` / `### Changed` subsections (create them if absent, keeping Keep-a-Changelog order):

```markdown
### Fixed

- Une demande qui ne progresse plus est désormais rattrapée automatiquement (Autodev #47). Une ligne `pending` sans `next_retry_at` était invisible pour toutes les passes de poll : ni redécouverte via GitLab (elle porte `label_doing`), ni reprise par les retries (qui exigent un horodatage). 14 demandes étaient ainsi gelées, la plus ancienne depuis avril.
- Une demande close ou réassignée sur GitLab pendant qu'elle était en attente ou en erreur est désormais détectée (Autodev #48). Le balayage ne regardait que les demandes actives, en supposant qu'une ligne finit toujours par bouger — ce qui est faux pour une ligne dormante.
- Une demande figée par l'arrêt brutal d'un worker (`cloning`, `implementing`, `answering_question`, `fixing_discussions`…) est désormais relancée sans attendre un redémarrage du service.

### Changed

- La passe `dispatch_error_recheck` devient `dispatch_dormant_audit` et couvre trois populations au lieu d'une. Les réglages `error_recheck_max` / `error_recheck_backoff` deviennent `dormant_audit_max` / `dormant_audit_backoff` ; les anciens noms restent acceptés.
```

- [ ] **Step 2: Update the `CLAUDE.md` dispatcher section**

In the `### PollDispatcher + IssueProcessJob` section, the pass list says "Six dispatch passes per project" and is missing the two added since. Replace the count and the list so it reads:

```markdown
`app/services/autodev/poll_dispatcher.rb` runs one polling cycle per call: discovers issues from GitLab + DB, enqueues an `IssueProcessJob(project_path, issue_iid, action)` per work item. Eight dispatch passes per project:

- `dispatch_new_issues` — new `label_todo` issues → `:process`
- `dispatch_pipelines` — `checking_pipeline` rows → `:check_pipeline`
- `dispatch_discussions` — `fixing_discussions` rows → `:fix_discussions`
- `dispatch_unassignment` — active rows closed on GitLab or no longer assigned → done inline (no job)
- `dispatch_done_unassigned` — `done` rows with `post_completion` configured → `:post_completion`
- `dispatch_dormant_audit` — rows that stopped moving (orphaned `pending`, spent-budget `error`, worker-pruned active states) → closed / done / re-armed inline, at most `dormant_audit_max` times per row
- `dispatch_retries` — `error` + `pending` with backoff elapsed → `:retry_errored` / `:retry_stuck`
- `dispatch_infra_recheck` — `done` + `stagnation_pipeline` rows → `:recheck_infra`
```

Then, in the **Error Handling** table, add the two rows:

```markdown
| Row dormant (`pending` with no `next_retry_at`, `error` with a spent budget, active state frozen 2h) | `dispatch_dormant_audit` gives it a bounded second look: closed on GitLab → `closed`, unassigned → `done`, still ours → re-armed. After `dormant_audit_max` fruitless rounds: `needs_attention` (`dormant_exhausted`) |
| Interrupted `fixing_discussions` / `answering_question` | Revived by `Issue.revive_stalled!` — at startup and, if the service does not restart, by the dormant audit |
```

- [ ] **Step 3: Verify the docs render**

Run: `bundle exec rake test TEST=test/help_doc_test.rb`
Expected: PASS.

- [ ] **Step 4: Run the full suite and RuboCop one last time**

Run: `bundle exec rake test && mise x ruby -- rubocop`
Expected: no failures, no offenses.

- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md CLAUDE.md
git commit -m "docs: record the dormant-rows audit (Autodev #47, #48)

Changelog entry for both tickets, and the PollDispatcher pass list in
CLAUDE.md — which still said six passes and predated both the infra recheck
and this one."
```

---

## Acceptance

The two rows found on 2026-08-06 and left in place on purpose are the recipe test. After deploying, on the first cycle:

- `#16207` (closed on GitLab, still `pending`) must become `closed` with `finished_at` stamped.
- `#15909` (unassigned, still `pending`) must become `done`.

One row per routing outcome. If either does not move on the first pass, the fix is wrong.
