# The pass writes the state it selects on — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A poll pass reserves the row it enqueues, so a job can never be enqueued twice for the same unit of budget; and the two `error` recovery paths become symmetric and stop relaunching work on a ticket a human has taken back.

**Architecture:** Three tickets, one rule. `dispatch_infra_recheck` moves `infra_recheck_at` under a conditional UPDATE before enqueueing (#110). `perform_retry_errored` clears `next_retry_at` like its sibling (#111) and asks the existing handover question before relaunching (#102), reached from the job through a twelve-line `HandoverStop` wrapper around `ExternalState` so the question keeps exactly one definition.

**Tech Stack:** Rails 8.1.3, ActiveRecord (**not** Sequel — see Task 1), Solid Queue, Minitest, RuboCop, I18n.

**Spec:** `docs/superpowers/specs/2026-09-04-the-pass-writes-what-it-selects-on-design.md`

## Global Constraints

- **TDD.** Every test verified red before its implementation, and red again with the implementation removed.
- **RuboCop green on the whole tree**: `mise x ruby -- rubocop`. Never edit any `.rubocop.yml`.
- **`CHANGELOG.md` `[Unreleased]`** updated in the same pass as the code (Task 6).
- **Conventional Commits**, types `feat` / `fix` / `refactor` / `test` / `docs` / `chore`.
- **i18n `fr` AND `en`** for every visible string. Task 5 is expected to need **no new key** — `stop_on_handover` builds `:"handover_#{verdict.reason}"` and those keys exist. If you find yourself adding one, stop and re-read: it means you are writing a second sentence for a stop that already has one.
- **Every test file must pass run on its own**: `bundle exec ruby -Itest test/<file>_test.rb` (Autodev #64), not only under `bundle exec rake test`.
- **Do not touch** `lib/autodev/boot_guard.rb`, `lib/autodev/supervisor.rb` or `app/services/autodev/review_arrears_sweep.rb` — they belong to the other two branches of the alpha 54 lot.

---

## File Structure

- **Modify** `app/services/autodev/poll_dispatcher.rb` — the reservation (#110), the stale ORM comment, the `ACTIVE_STATUSES` decision comment (#102).
- **Modify** `lib/autodev/pipeline_monitor/infra_recheck.rb` — `record_recheck_attempt` stops owning the clock, and the cap becomes a guard.
- **Modify** `lib/autodev/config.rb` — `Config.infra_recheck_max` / `Config.infra_recheck_backoff`, so the two files read one lookup.
- **Modify** `app/jobs/issue_process_job.rb` — `perform_retry_errored` (#111 + #102).
- **Create** `app/services/autodev/handover_stop.rb` — the `ExternalState` carrier for callers that are not poll-cycle services.
- **Create** `test/infra_recheck_reservation_test.rb`, `test/retry_clears_its_decision_test.rb`, `test/errored_retry_respects_a_handover_test.rb`.
- **Modify** `CLAUDE.md`, `CHANGELOG.md` — Task 6.

---

### Task 1: One lookup for the infra-recheck settings

**Files:**
- Modify: `lib/autodev/config.rb`
- Modify: `app/services/autodev/poll_dispatcher.rb:461-465` (`infra_recheck_max`)
- Modify: `lib/autodev/pipeline_monitor/infra_recheck.rb:113-121` (`infra_recheck_max`, `infra_recheck_backoff_seconds`)

**Interfaces:**
- Consumes: nothing.
- Produces: `Config.infra_recheck_max(project_config, config) -> Integer` and `Config.infra_recheck_backoff(project_config, config) -> Integer`, both following the shape of the existing `Config.max_retries(project_config, config)`.

`infra_recheck_max` is **already** duplicated between the dispatcher and the monitor. Task 2 needs the backoff in the dispatcher too, and copying a second lookup across the same two files is how the two drift apart. Do this first so Task 2 has one place to read from.

- [ ] **Step 1: Read the existing shape**

Run: `grep -n "def self.max_retries" -A 8 lib/autodev/config.rb`
Copy that shape exactly — same fallback order (project config → global config → baked default), same `.to_i`.

- [ ] **Step 2: Write the failing test**

Create `test/infra_recheck_settings_test.rb`:

```ruby
# frozen_string_literal: true

require_relative 'test_helper'

# Autodev #110: the dispatcher reserves the row and therefore needs the backoff
# the monitor used to own alone. Two copies of one lookup is how two answers
# drift apart, so both read Config.
class InfraRecheckSettingsTest < Minitest::Test
  def test_the_project_value_wins_over_the_global_one
    assert_equal 7, ::Config.infra_recheck_max({ 'infra_recheck_max' => 7 },
                                               { 'infra_recheck_max' => 3 })
    assert_equal 90, ::Config.infra_recheck_backoff({ 'infra_recheck_backoff' => 90 },
                                                    { 'infra_recheck_backoff' => 30 })
  end

  def test_the_global_value_is_used_when_the_project_says_nothing
    assert_equal 3, ::Config.infra_recheck_max({}, { 'infra_recheck_max' => 3 })
    assert_equal 30, ::Config.infra_recheck_backoff({}, { 'infra_recheck_backoff' => 30 })
  end

  def test_the_baked_defaults_are_the_pipeline_monitors
    assert_equal ::PipelineMonitor::DEFAULT_INFRA_RECHECK_MAX, ::Config.infra_recheck_max({}, {})
    assert_equal ::PipelineMonitor::DEFAULT_INFRA_RECHECK_BACKOFF, ::Config.infra_recheck_backoff({}, {})
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `bundle exec ruby -Itest test/infra_recheck_settings_test.rb`
Expected: FAIL — `undefined method 'infra_recheck_max' for Config`.

- [ ] **Step 4: Implement, then delete both duplicates**

Add the two class methods to `lib/autodev/config.rb`, then replace the private `infra_recheck_max` in `poll_dispatcher.rb` and both private readers in `infra_recheck.rb` with calls to them. Keep the call sites reading `Config.infra_recheck_max(@project_config, @config)`.

- [ ] **Step 5: Run the tests**

Run: `bundle exec ruby -Itest test/infra_recheck_settings_test.rb && bundle exec rake test`
Expected: PASS, and no regression — the existing infra-recheck tests must be untouched by this.

- [ ] **Step 6: Commit**

```bash
git add lib/autodev/config.rb app/services/autodev/poll_dispatcher.rb lib/autodev/pipeline_monitor/infra_recheck.rb test/infra_recheck_settings_test.rb
git commit -m "refactor: one lookup for the infra-recheck settings

Autodev #110 preparation. infra_recheck_max was already spelled out in both the
dispatcher and the monitor; the reservation needs the backoff in the dispatcher
too, and a second copy across the same two files is how two answers drift."
```

---

### Task 2: `dispatch_infra_recheck` reserves the row before enqueueing

**Files:**
- Modify: `app/services/autodev/poll_dispatcher.rb:444-460`
- Modify: `lib/autodev/pipeline_monitor/infra_recheck.rb:108-112` (`record_recheck_attempt`)
- Create: `test/infra_recheck_reservation_test.rb`

**Interfaces:**
- Consumes: `Config.infra_recheck_backoff` / `Config.infra_recheck_max` from Task 1.
- Produces: nothing new. `dispatch_infra_recheck` keeps its name and signature; `record_recheck_attempt` keeps its name and stops writing `infra_recheck_at`.

**The models are ActiveRecord 8.1.3, not Sequel.** The comment at the head of `PollDispatcher` (`:15`) says otherwise and is stale — `Issue < ApplicationRecord` (`app/models/issue.rb:12`), and the same file rescues `ActiveRecord::RecordNotUnique`. Correct that comment as part of this task: it is what would send you to `Sequel.expr`. The idiom to copy is `Issue.reset_for_retry!` (`app/models/issue.rb:409`), a `where(...).update_all(...)` whose return value is the count.

**What is written and what is not.** The reservation moves `infra_recheck_at` only. It must **not** increment `infra_recheck_count`, because `record_recheck_attempt` is called `if verdict == :spend` (`infra_recheck.rb:31`) and the two verdicts that read nothing — a GitLab error, a transient MR state — deliberately spend nothing. Spending at enqueue would let a five-minute GitLab outage burn the whole watch budget, which is this ticket's own harm reintroduced from the other side.

- [ ] **Step 1: Write the failing tests**

Create `test/infra_recheck_reservation_test.rb`:

```ruby
# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'

# Autodev #110, measured in production on 04/09/2026 (powerpanne/core#16030):
# five enqueues in eighty seconds, all announcing "attempt 5", then jobs running
# 5/5, 6/5, 7/5, 8/5, 9/5. The dispatcher selected on two columns only the job
# wrote, so every cycle between the enqueue and the execution re-selected the
# same row.
class InfraRecheckReservationTest < Minitest::Test
  include DatabaseTestHelper

  def setup
    reset_database!
    @path = 'group/project'
    @issue = ::Issue.create!(project_path: @path, issue_iid: 16_030, status: 'done',
                             mr_iid: 11_333, needs_attention: true,
                             attention_reason: 'stagnation_pipeline',
                             infra_recheck_count: 0, infra_recheck_at: nil)
  end

  def test_two_dispatch_cycles_without_a_job_running_enqueue_one_job
    enqueued = capture_enqueued do
      dispatcher.send(:dispatch_infra_recheck)
      dispatcher.send(:dispatch_infra_recheck)
    end

    assert_equal 1, enqueued.size,
                 'the second cycle must find the row reserved and enqueue nothing'
  end

  def test_the_reservation_moves_the_backoff_stamp_and_not_the_counter
    capture_enqueued { dispatcher.send(:dispatch_infra_recheck) }
    @issue.reload

    refute_nil @issue.infra_recheck_at, 'the dispatcher owns the clock now'
    assert_operator @issue.infra_recheck_at, :>, Time.current
    assert_equal 0, @issue.infra_recheck_count,
                 'the budget is spent by an attempt that looked at something, not by an enqueue'
  end

  def test_a_row_whose_backoff_has_not_elapsed_is_not_selected
    @issue.update!(infra_recheck_at: 1.hour.from_now)

    enqueued = capture_enqueued { dispatcher.send(:dispatch_infra_recheck) }

    assert_empty enqueued
  end

  def test_a_row_at_the_cap_is_not_selected
    @issue.update!(infra_recheck_count: 5)

    enqueued = capture_enqueued { dispatcher.send(:dispatch_infra_recheck) }

    assert_empty enqueued
  end

  private

  def dispatcher
    Autodev::PollDispatcher.new(client: Object.new, path: @path, config: {},
                                project_config: { 'path' => @path },
                                logger: Autodev::JobLogger.new(Logger.new(File::NULL)))
  end

  # IssueProcessJob.perform_later is the seam; record the calls instead of
  # booting the queue.
  def capture_enqueued
    calls = []
    IssueProcessJob.stub(:perform_later, ->(*args) { calls << args }) { yield }
    calls
  end
end
```

Check `PollDispatcher.new`'s real keyword list first (`grep -n "def initialize" -A 12 app/services/autodev/poll_dispatcher.rb`) and match it exactly — the constructor above is the expected shape, not a guess to keep if it differs.

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec ruby -Itest test/infra_recheck_reservation_test.rb`
Expected: FAIL — `test_two_dispatch_cycles_without_a_job_running_enqueue_one_job` gets 2, which is the production defect reproduced.

- [ ] **Step 3: Implement the reservation**

Replace `dispatch_infra_recheck` in `app/services/autodev/poll_dispatcher.rb`:

```ruby
    # Autodev #110. The row is **reserved** before the job is enqueued, by moving
    # the one column the selection races on. Without it every cycle between the
    # enqueue and the execution re-selected the same row: five enqueues in eighty
    # seconds on 04/09/2026, then five jobs each spending an attempt, `9/5`.
    #
    # Who owns what, and it is not symmetric on purpose:
    #   * this pass owns `infra_recheck_at` — the clock it selects on;
    #   * `InfraRecheck#record_recheck_attempt` owns `infra_recheck_count` — the
    #     budget, spent only by an attempt that actually read a pipeline
    #     (`verdict == :spend`), so a GitLab outage cannot burn the whole watch
    #     window without ever having looked.
    #
    # The UPDATE repeats the whole predicate rather than matching on `id`: that
    # is what makes it a compare-and-set, so two cycles racing on one row cannot
    # both match.
    def dispatch_infra_recheck
      fetch_infra_recheck_candidates.each do |issue|
        next unless reserve_infra_recheck(issue)

        IssueProcessJob.perform_later(@path, issue.issue_iid, :recheck_infra)
        @logger.info("Enqueued infra recheck for issue ##{issue.issue_iid} " \
                     "(attempt #{(issue.infra_recheck_count || 0) + 1})", project: @path)
      end
    end

    def reserve_infra_recheck(issue)
      ::Issue.where(id: issue.id, project_path: @path, status: 'done',
                    needs_attention: true, attention_reason: 'stagnation_pipeline')
             .where('infra_recheck_count < ?', Config.infra_recheck_max(@project_config, @config))
             .where("infra_recheck_at IS NULL OR infra_recheck_at <= datetime('now')")
             .update_all(infra_recheck_at: Config.infra_recheck_backoff(@project_config,
                                                                        @config).seconds.from_now)
             .positive?
    end
```

In `lib/autodev/pipeline_monitor/infra_recheck.rb`, `record_recheck_attempt` stops writing the stamp:

```ruby
    # Records one bounded attempt. The **clock** belongs to
    # `PollDispatcher#dispatch_infra_recheck`, which moves `infra_recheck_at` to
    # reserve the row before the job is enqueued (Autodev #110); this method owns
    # the budget alone, and is reached only on `verdict == :spend` — an outage or
    # a transient MR state spends nothing, which is why the two columns cannot
    # both be written in the same place.
    def record_recheck_attempt(issue)
      max = ::Config.infra_recheck_max(@project_config, @config)
      attempt = (issue.infra_recheck_count || 0) + 1
      return log_recheck_overrun(issue, attempt, max) if attempt > max

      issue.update(infra_recheck_count: attempt)
      log "Issue ##{issue.issue_iid}: infra recheck attempt #{attempt}/#{max}, backing off"
    end

    # Autodev #110: the old code logged `9/5` and wrote it anyway. A logged
    # overrun with no consequence is what kept the defect invisible for a night.
    def log_recheck_overrun(issue, attempt, max)
      log_error "Issue ##{issue.issue_iid}: refusing to record infra recheck attempt " \
                "#{attempt} past the cap of #{max}"
    end
```

Also correct the stale ORM sentence at `poll_dispatcher.rb:15` — the models are ActiveRecord, dynamically defined by nothing.

- [ ] **Step 4: Run the tests**

Run: `bundle exec ruby -Itest test/infra_recheck_reservation_test.rb`
Expected: PASS, 4 runs.

Run: `bundle exec rake test`
Expected: no regression. The existing infra-recheck tests assert `record_recheck_attempt` writes both columns — those assertions are now wrong and must be **updated with their reason**, not deleted.

- [ ] **Step 5: Prove the central test has teeth**

Remove the `next unless reserve_infra_recheck(issue)` line, re-run, and confirm `test_two_dispatch_cycles_without_a_job_running_enqueue_one_job` fails with 2. Restore.

- [ ] **Step 6: Commit**

```bash
git add app/services/autodev/poll_dispatcher.rb lib/autodev/pipeline_monitor/infra_recheck.rb test/infra_recheck_reservation_test.rb
git commit -m "fix: the infra recheck reserves the row it enqueues (Autodev #110)

Measured on powerpanne/core#16030, 04/09/2026: five enqueues in eighty seconds
all announcing attempt 5, then jobs running 5/5 through 9/5. infra_recheck_count
reached 9 for a cap of 5, which no automatic pass can select any more, and a
watch budget meant for five hourly looks at a recovering CI was spent in four
minutes.

The dispatcher now owns infra_recheck_at and moves it under a conditional UPDATE
that repeats the selection predicate, so two cycles racing on one row cannot both
match. The counter stays in the job, because it is spent only by an attempt that
read a pipeline — spending it at enqueue would let an outage burn the budget
without ever having looked, which is this ticket's harm from the other side. And
the cap is a guard now: an overrun is refused rather than logged and written."
```

---

### Task 3: The neighbouring passes are not exposed, and that is asserted

**Files:**
- Create: `test/a_duplicate_job_finds_nothing_to_do_test.rb`

**Interfaces:**
- Consumes: `IssueProcessJob::DISPATCHED_FROM`.
- Produces: nothing.

`dispatch_retries`, `dispatch_pipelines` and `dispatch_discussions` enqueue duplicates too — four "Enqueued discussion fix … (round 1)" in fifteen seconds were observed on 03/09 at 21:23. They do not bleed because `DISPATCHED_FROM` (Autodev #61) skips a job whose row has left the state it was dispatched from, and their work moves the row. `recheck_infra` was the exception because `done` survives its own work.

Assert that, rather than leaving it as a comment nobody can check. This is the test that stops the same exposure appearing elsewhere unnoticed.

- [ ] **Step 1: Write the test**

```ruby
# frozen_string_literal: true

require_relative 'test_helper'

# Autodev #110. Every dispatch pass enqueues its whole population each cycle, so
# duplicates are normal. What makes them harmless is DISPATCHED_FROM (Autodev
# #61): the work moves the row out of the state its action was dispatched from,
# so the copy is skipped.
#
# `recheck_infra` is the one action whose precondition SURVIVES its own work — a
# recheck that finds CI still broken leaves the row `done` — which is why it
# needed a reservation and its neighbours did not. If a future action joins that
# category, this test is where somebody finds out.
class ADuplicateJobFindsNothingToDoTest < Minitest::Test
  # An action is "self-clearing" when performing it necessarily moves the row out
  # of every state it is dispatched from. Stated per action, with the transition
  # that does the moving, so adding an action forces the question to be answered.
  SELF_CLEARING = {
    process: 'IssueProcessor#process leaves PROCESSABLE_STATES on start_processing!',
    check_pipeline: 'a conclusive poll leaves checking_pipeline; an inconclusive one re-reads harmlessly',
    fix_discussions: 'a round ends on discussions_fixed! or an abandon, leaving fixing_discussions',
    post_completion: 'the hook transitions through running_post_completion',
    retry_errored: 'retry_pipeline! / retry_processing! leave error',
    retry_stuck: 'IssueProcessor#process leaves pending'
  }.freeze

  # The exception, and the reason it needs a reservation instead.
  RESERVED = {
    recheck_infra: 'a recheck that does not recover leaves the row `done`, so the ' \
                   'state guard cannot tell a duplicate apart — PollDispatcher#reserve_infra_recheck does'
  }.freeze

  def test_every_dispatched_action_is_declared_self_clearing_or_reserved
    declared = SELF_CLEARING.keys + RESERVED.keys

    assert_equal IssueProcessJob::DISPATCHED_FROM.keys.sort, declared.sort,
                 'a new action must declare whether its precondition survives its own work'
  end

  def test_the_reserved_action_is_reserved_by_the_dispatcher
    assert Autodev::PollDispatcher.private_method_defined?(:reserve_infra_recheck),
           'recheck_infra is declared as reserved, so the reservation must exist'
  end
end
```

- [ ] **Step 2: Run**

Run: `bundle exec ruby -Itest test/a_duplicate_job_finds_nothing_to_do_test.rb`
Expected: PASS. If `DISPATCHED_FROM` has an action not listed above, add it to the right table **with its reason** — do not adjust the assertion.

- [ ] **Step 3: Commit**

```bash
git add test/a_duplicate_job_finds_nothing_to_do_test.rb
git commit -m "test: declare, per action, whether its precondition survives its own work

Autodev #110. The neighbours of dispatch_infra_recheck enqueue duplicates too and
do not bleed, because DISPATCHED_FROM skips them once the work has moved the row.
That was a comment; it is a check now, so a future action in the same category as
recheck_infra cannot arrive unnoticed."
```

---

### Task 4: `perform_retry_errored` clears the retry decision (#111)

**Files:**
- Modify: `app/jobs/issue_process_job.rb:183-189`
- Create: `test/retry_clears_its_decision_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

- [ ] **Step 1: Write the failing tests**

```ruby
# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'

# Autodev #111. perform_retry_stuck clears next_retry_at as its first statement;
# perform_retry_errored cleared error_message and started_at and left the stamp.
# Observed on powerpanne/core#16030, 03/09/2026: next_retry_at = 03/09 18:30, in
# the past, on a row no longer in `error`.
#
# The rule: entering `error` writes the retry decision (mark_failed), leaving it
# erases it. PollDispatcher.retryable? reads the stamp and nothing else, so a
# residue is a decision nobody took.
class RetryClearsItsDecisionTest < Minitest::Test
  include DatabaseTestHelper

  def setup
    reset_database!
  end

  def test_an_errored_retry_clears_the_stamp
    issue = errored_issue(mr_iid: 11_333)

    run_retry(issue, :retry_errored)

    assert_nil issue.reload.next_retry_at,
               'leaving error must erase the decision that scheduled the return'
  end

  def test_a_stuck_retry_clears_the_stamp
    issue = ::Issue.create!(project_path: 'group/project', issue_iid: 2, status: 'pending',
                            next_retry_at: 1.hour.ago, retry_count: 1)

    run_retry(issue, :retry_stuck)

    assert_nil issue.reload.next_retry_at
  end

  private

  def errored_issue(mr_iid:)
    ::Issue.create!(project_path: 'group/project', issue_iid: 1, status: 'error',
                    mr_iid: mr_iid, next_retry_at: 1.hour.ago, retry_count: 1,
                    error_message: 'boom')
  end
end
```

Write `run_retry` against the job's real seams — read `perform_retry_errored`'s collaborators (`restore_working_label`, `log_retry_activity`) and stub the two GitLab-touching ones. `grep -n "def worker_kwargs\|def build_client" app/jobs/issue_process_job.rb` gives you the seam. Do not invent a helper the file does not have.

- [ ] **Step 2: Run to verify the errored case fails**

Run: `bundle exec ruby -Itest test/retry_clears_its_decision_test.rb`
Expected: FAIL on `test_an_errored_retry_clears_the_stamp` — the stamp is still `1.hour.ago`.

- [ ] **Step 3: Implement**

In `perform_retry_errored`, add `next_retry_at: nil` to the existing update and write the rule as a comment covering both methods:

```ruby
  # Autodev #111. Entering `error` writes the retry decision (`mark_failed`
  # stamps `next_retry_at`); leaving it erases that decision. Both recovery
  # paths do it — they used not to, for no reason written anywhere, and
  # `PollDispatcher.retryable?` reads the stamp, `retry_count` and nothing else,
  # so a residue is a scheduled return nobody decided on. It survived only
  # because `fetch_retryable` filters on status; that filter is a second line,
  # not the rule.
  def perform_retry_errored(issue, config, project_config)
    has_mr = !issue.mr_iid.nil?
    has_mr ? issue.retry_pipeline! : issue.retry_processing!
    issue.update(error_message: nil, started_at: nil, next_retry_at: nil)
    restore_working_label(issue, config, project_config)
    log_retry_activity(issue, config, project_config)
  end
```

- [ ] **Step 4: Run**

Run: `bundle exec ruby -Itest test/retry_clears_its_decision_test.rb && bundle exec rake test`
Expected: PASS, no regression.

- [ ] **Step 5: Report the existing residues without cleaning them**

Run, read-only, against the development copy of the production database:

```bash
bundle exec rails runner 'puts Issue.where.not(next_retry_at: nil).where.not(status: %w[error pending]).count'
```

Record the number for the changelog. **Do not write to production.** The invariant holds from here; cleaning historic rows is a production write with no benefit and it is out of scope by decision, not by omission.

- [ ] **Step 6: Commit**

```bash
git add app/jobs/issue_process_job.rb test/retry_clears_its_decision_test.rb
git commit -m "fix: leaving error erases the retry decision (Autodev #111)

perform_retry_stuck cleared next_retry_at, perform_retry_errored did not, and no
reason was written anywhere. Autodev #103 handled the entry into error and left
the exit. PollDispatcher.retryable? reads that stamp and nothing else, so a
residue makes a row a candidate the moment its status passes back through error
or pending, with no mark_failed having decided it — the protection held only by
fetch_retryable's status filter, which is a second line and not the rule."
```

---

### Task 5: An errored retry asks whether a human took the ticket back (#102)

**Files:**
- Create: `app/services/autodev/handover_stop.rb`
- Modify: `app/jobs/issue_process_job.rb` (`perform_retry_errored`)
- Modify: `app/services/autodev/poll_dispatcher.rb` (the `ACTIVE_STATUSES` decision comment)
- Create: `test/errored_retry_respects_a_handover_test.rb`

**Interfaces:**
- Consumes: `ExternalState#stop_on_handover(issue, gl_issue)` (`app/services/autodev/external_state.rb:61`), which returns a verdict or `nil` and, on a verdict, posts the notice and closes the row through `close_row!`.
- Produces: `Autodev::HandoverStop.new(client:, path:, project_config:, logger:)` exposing `stop_on_handover(issue, gl_issue)`.

`error` is in the `close` event's `from` list (`app/models/issue.rb:191`), so `may_close?` — `stop_on_handover`'s own precondition — holds. `ACTIVE_STATUSES` is **not** widened: it is documented as a boundary in six places including four tests, and it governs other passes' populations.

- [ ] **Step 1: Write the failing tests**

```ruby
# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'

# Autodev #102. dispatch_unassignment sweeps ACTIVE_STATUSES and `error` is not
# in it, so an errored row was never asked whether a human had taken the ticket
# back — and `error` is exactly the state where that is most likely: autodev
# failed, the ticket carries label_attention or stayed on label_doing, and
# somebody who sees that moves it into their own column.
#
# dispatch_retries then relaunched the row, restore_working_label re-applied
# autodev's working label on a ticket somebody was holding, and the takeover was
# only detected a cycle later — after the write, and possibly after a delivery.
class ErroredRetryRespectsAHandoverTest < Minitest::Test
  include DatabaseTestHelper

  def setup
    reset_database!
    @issue = ::Issue.create!(project_path: 'group/project', issue_iid: 1, status: 'error',
                             mr_iid: 11_333, next_retry_at: 1.hour.ago, retry_count: 1)
  end

  def test_a_taken_over_ticket_is_not_relaunched
    run_retry_with_handover(taken_over: true)
    @issue.reload

    assert_equal 'closed', @issue.status, 'a ticket somebody holds must not be relaunched'
    assert_empty labels_written, 'and autodev must not repose its working label on it'
  end

  def test_an_untouched_ticket_is_relaunched_exactly_as_before
    run_retry_with_handover(taken_over: false)
    @issue.reload

    assert_equal 'checking_pipeline', @issue.status
    refute_empty labels_written, 'the nominal path must be unchanged'
  end

  def test_a_gitlab_read_that_fails_leaves_the_row_untouched
    run_retry_with_handover(raises: Autodev::ApiUnavailableError.new('gitlab is down'))
    @issue.reload

    assert_equal 'error', @issue.status,
                 'a read that could not answer is not permission to relaunch'
    assert_empty labels_written
  end
end
```

Write the three helpers (`run_retry_with_handover`, `labels_written`) against the job's real seams. `restore_working_label` goes through `MrFixer#apply_label_doing`, so stubbing `MrFixer` is where `labels_written` comes from. Read the methods before writing the harness; do not invent seams.

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec ruby -Itest test/errored_retry_respects_a_handover_test.rb`
Expected: FAIL — the row is relaunched in all three cases, which is the defect.

- [ ] **Step 3: Create the carrier**

`app/services/autodev/handover_stop.rb`:

```ruby
# frozen_string_literal: true

module Autodev
  # Autodev #102. `ExternalState` is a mixin for poll-cycle services carrying
  # `@client`, `@path`, `@project_config` and `@logger`; `IssueProcessJob` is not
  # one of those, and the question it needs — "has a human taken this ticket
  # back?" — already has exactly one definition there, together with the notice
  # and the terminal write that follow a yes.
  #
  # So this carries the ivars and nothing else. It deliberately has no logic of
  # its own: anything added here is an answer that can drift from
  # `PollDispatcher`'s, which is the fault Autodev #93 avoided by extracting
  # `UntouchedSinceGiveup` rather than writing the question twice.
  class HandoverStop
    include ExternalState

    def initialize(client:, path:, project_config:, logger:)
      @client = client
      @path = path
      @project_config = project_config
      @logger = logger
    end
  end
end
```

If `stop_on_handover` is private in the mixin, make it public **in `HandoverStop` only** with `public :stop_on_handover` and a one-line reason — do not change `ExternalState`'s own visibility.

- [ ] **Step 4: Ask the question before relaunching**

In `perform_retry_errored`, read the ticket once and ask first:

```ruby
  def perform_retry_errored(issue, config, project_config)
    return if handed_over?(issue, config, project_config)

    has_mr = !issue.mr_iid.nil?
    has_mr ? issue.retry_pipeline! : issue.retry_processing!
    issue.update(error_message: nil, started_at: nil, next_retry_at: nil)
    restore_working_label(issue, config, project_config)
    log_retry_activity(issue, config, project_config)
  end

  # Autodev #102. `error` is outside `dispatch_unassignment`'s ACTIVE_STATUSES
  # sweep, so this is the only place the question gets asked before autodev
  # writes on the ticket again. A read that could not answer declines the retry
  # for this cycle and leaves the row exactly as it was — the Autodev #67 rule,
  # and the choice Autodev #93 made for `UntouchedSinceGiveup`: an unreadable
  # ticket is never permission to take it.
  #
  # Costs one GitLab read per errored retry — not per poll cycle. `manage_labels`
  # does read the issue, but inside `apply_label_doing`, i.e. after the
  # transition, which is too late to be the one this needs.
  def handed_over?(issue, config, project_config)
    client = build_client(config)
    gl_issue = client.issue(project_config['path'], issue.issue_iid)
    stopper = ::Autodev::HandoverStop.new(client: client, path: project_config['path'],
                                          project_config: project_config,
                                          logger: ::Autodev::JobLogger.new(logger))
    !stopper.stop_on_handover(issue, gl_issue).nil?
  rescue ::Autodev::ApiUnavailableError, ::Gitlab::Error::ResponseError => e
    logger.warn("Declining the retry of ##{issue.issue_iid}: could not read the ticket " \
                "(#{e.class}: #{e.message})")
    true
  end
```

Check `build_client`'s real name and signature before using it (`grep -n "def build_client" -A 4 app/jobs/issue_process_job.rb`).

Add beside `dispatch_unassignment` in `poll_dispatcher.rb`:

```ruby
    # `error` is deliberately NOT in ACTIVE_STATUSES (Autodev #102). Widening the
    # constant would change the population of every pass that reads it, for a
    # defect that lives in one method: `IssueProcessJob#perform_retry_errored`
    # asks the same question through `Autodev::HandoverStop` before it relaunches.
```

- [ ] **Step 5: Run**

Run: `bundle exec ruby -Itest test/errored_retry_respects_a_handover_test.rb && bundle exec rake test`
Expected: PASS, no regression.

- [ ] **Step 6: Prove one definition, not two**

Add to the same file:

```ruby
  def test_handover_stop_adds_no_logic_of_its_own
    own = Autodev::HandoverStop.instance_methods(false) - [:stop_on_handover]

    assert_empty own, 'HandoverStop carries ivars; any method here is an answer free to drift'
  end
```

- [ ] **Step 7: Commit**

```bash
git add app/services/autodev/handover_stop.rb app/jobs/issue_process_job.rb app/services/autodev/poll_dispatcher.rb test/errored_retry_respects_a_handover_test.rb
git commit -m "fix: an errored retry asks whether a human took the ticket back (Autodev #102)

dispatch_unassignment sweeps ACTIVE_STATUSES and error is not in it, so the one
state where a human takeover is most likely was never checked. The retry then
reposed autodev's working label on a ticket somebody was holding, and a
successful one could deliver over their work; the takeover was only detected the
cycle after, because dispatch_unassignment runs before dispatch_retries.

The question is not rewritten: ExternalState#stop_on_handover already is the
question, the notice and the terminal write, and error is in the close event's
sources. HandoverStop carries the ivars for a caller that is not a poll-cycle
service, and a test asserts it carries nothing else. ACTIVE_STATUSES is
untouched — it is a documented boundary in six places and governs other passes."
```

---

### Task 6: Docs, changelog, and the full gate

**Files:**
- Modify: `CLAUDE.md` (the `PollDispatcher` pass list, and the error-handling row for the infra recheck)
- Modify: `CHANGELOG.md` (`[Unreleased]`)

- [ ] **Step 1: `CLAUDE.md`**

In the eight-pass list, `dispatch_infra_recheck`'s bullet gains the reservation and the ownership split. Add one sentence to the pass list stating the rule in general terms — a pass writes the state it selects on — since it is now true of the whole file and is what a future pass should copy.

- [ ] **Step 2: `CHANGELOG.md`**

One `### Fixed` entry under `[Unreleased]`, covering the three tickets as one change, in the register of the existing entries. It must carry:
- the 04/09 measurement: five enqueues in eighty seconds, jobs running `5/5` to `9/5`, `infra_recheck_count` at 9 for a cap of 5, the row selectable by no automatic pass, the lost watch window;
- why the counter stayed in the job (the outage invariant), since that is the part that reads as an inconsistency without its reason;
- the residue count from Task 4 Step 5, and the decision not to clean it;
- that `ACTIVE_STATUSES` was instructed and deliberately not widened.

- [ ] **Step 3: Full gate**

Run: `bundle exec rake test`
Expected: 0 failures, 0 errors.

Run each new file standalone (Autodev #64):
```bash
for f in infra_recheck_settings infra_recheck_reservation a_duplicate_job_finds_nothing_to_do retry_clears_its_decision errored_retry_respects_a_handover; do
  bundle exec ruby -Itest "test/${f}_test.rb" || echo "FAILED STANDALONE: $f"
done
```
Expected: no `FAILED STANDALONE` line.

Run: `mise x ruby -- rubocop`
Expected: no offenses, whole tree.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md CHANGELOG.md
git commit -m "docs: record the reservation rule and the 04/09 measurement

Autodev #110, #111, #102."
```

---

## Definition of done

- `bundle exec rake test` green; each new test file green standalone.
- `mise x ruby -- rubocop` clean on the whole tree.
- Two dispatch cycles with no job between them enqueue one job, asserted.
- `infra_recheck_count` is written by the job only, `infra_recheck_at` by the dispatcher only, and both are stated in comments at each site.
- A cap overrun is refused and logged, never written.
- `next_retry_at` is nil after both recovery paths, one test each.
- An errored retry on a taken-over ticket writes no label and closes the row; on an unreadable ticket it writes nothing at all.
- `ACTIVE_STATUSES` unchanged, with the decision written beside it.
- `CHANGELOG.md` `[Unreleased]` carries the three tickets and the measurement.
