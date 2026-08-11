# Manual pipeline status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop a `manual` pipeline from parking a finished ticket in `checking_pipeline` forever. Resolve it on its blocking jobs instead of its roll-up status: no blocking job failed → green → `mr-review` → `label_done` (Autodev #51).

**Architecture:** One new `when` clause in `PipelineMonitor#dispatch_status` routes `manual` and `skipped` to a new `BlockedPipeline` module, which fetches the pipeline's jobs, drops the non-blocking ones (`allow_failure: true`, or an unplayed `manual` job) and branches: a failed blocking job → the existing `handle_red`; none → `handle_green`; the jobs endpoint unreachable → skip the cycle. `canceled` deliberately keeps today's behaviour and keeps its documented rationale. No new user-facing string.

**Tech Stack:** Rails 8.1.3, Minitest (`test/**/*_test.rb`), plain Ruby modules mixed into `PipelineMonitor`.

**Spec:** `docs/superpowers/specs/2026-08-11-manual-pipeline-status-design.md`

**Worktree:** `fix/51-manual-pipeline-status`, branched from `master` at `83f8c71`.

## Global Constraints

- **TDD.** Write the failing test, run it, watch it fail for the right reason, then implement.
- **RuboCop must pass**: `mise x ruby -- rubocop` from the worktree root. Baseline on this branch point: **46 offenses across 9 files**, all pre-existing Rails boilerplate. Never edit any `.rubocop.yml`.
- **Test baseline**: `mise x ruby -- bundle exec rake test` → 1350 runs, 2608 assertions, 0 failures, 0 errors.
- **Conventional Commits**: `<type>: <description> (Autodev #51)` plus a body explaining the why. End every commit message with `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- **`CHANGELOG.md` `[Unreleased]`** is updated in the same pass (Task 4). It is **not empty** — it carries four `### Fixed` bullets from #50/#54. Add to that section, do not create a second one.
- **This change adds no user-facing string.** Nothing under `config/locales/` changes; see the spec §3 for why the diagnostic stays in the technical log.
- **Language per document.** `CHANGELOG.md` and `CLAUDE.md` are English; `docs/usage/autodev-technical-usage.md` is **French**.
- **Do not touch the watch loop, `PollTracker`, or `activity_events` journalling.** Autodev #53 ("borner la surveillance de pipeline dans le temps") is being implemented in parallel on another branch and owns those. This plan adds one `when` clause and one module.
- **Do not change `canceled`.** It stays in the `else`. The spec §2 argues why; #53 supplies the bound.
- **Test commands** (from the worktree root):
  - one file: `mise x ruby -- bundle exec rake test TEST=test/<file>_test.rb`
  - full suite: `mise x ruby -- bundle exec rake test`

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `lib/autodev/pipeline_monitor/constants.rb` | `BLOCKED_STATUSES`, `NON_BLOCKING_JOB_STATUSES` | 2 |
| `lib/autodev/pipeline_monitor/api_helpers.rb` | `fetch_pipeline_jobs` — full job list, `nil` on API error | 2 |
| `lib/autodev/pipeline_monitor/job_classifier.rb` | `blocking_jobs` / `failed_blocking_jobs` | 2 |
| `lib/autodev/pipeline_monitor/blocked_pipeline.rb` | **New.** `dispatch_blocked` — the three-way branch | 2 |
| `lib/autodev/pipeline_monitor.rb` | One `when *BLOCKED_STATUSES` clause + the include/require | 2 |
| `test/pipeline_monitor_manual_status_test.rb` | **New.** The whole contract | 1 |
| `CHANGELOG.md`, `CLAUDE.md`, `docs/usage/autodev-technical-usage.md` | Docs | 3 |

---

### Task 1: The failing tests

**Files:**
- Create: `test/pipeline_monitor_manual_status_test.rb`

**Interfaces:**
- Consumes: `PipelineMonitor#dispatch_status(issue, pipeline)` (private), `#blocking_jobs(jobs)` (private, to be created).
- Produces: nothing later tasks consume.

**Shape of the harness:** modelled on `test/pipeline_monitor_infra_recheck_test.rb` — `PipelineMonitor.allocate`, `@client` set to a stub answering `pipeline_jobs`, `log`/`log_error` neutered. `handle_green` and `handle_red` are replaced by recorders: the point is the *routing decision*, not re-running the green or red pipeline, both of which are already covered elsewhere.

- [ ] **Step 1: Write the test file**

```ruby
# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/pipeline_monitor'

# Autodev #51 — a `manual` pipeline is resolved by its blocking jobs.
#
# GitLab reports `manual` when every job that could run has run and what is left
# needs a human. On a project whose MR pipelines end with a manual deploy_review
# that is the NORMAL end state of a green MR, and it used to fall in
# dispatch_status's `else`: log a line, do nothing, forever. Measured on
# powerpanne/core: pipeline 215229 read 12 729 times in 18 days, four tickets
# finished and never delivered until humans relabelled them by hand.
#
# The roll-up status cannot express "the jobs that gate the merge are green, the
# ones that gate a deploy are waiting for a human". The job list can, so the
# verdict is taken there: no blocking job failed → green.
class PipelineMonitorManualStatusTest < Minitest::Test
  FakePipeline = Struct.new(:id, :status)

  # Returns the configured job list, or raises to simulate an API failure.
  class StubClient
    attr_reader :jobs_calls

    def initialize(jobs: [], raise_error: false)
      @jobs = jobs
      @raise_error = raise_error
      @jobs_calls = 0
    end

    def pipeline_jobs(_project_path, _pid, **_opts)
      @jobs_calls += 1
      raise Gitlab::Error::ResponseError, 'boom' if @raise_error

      @jobs
    end
  end

  FakeIssue = Struct.new(:issue_iid, :mr_iid)

  # Records the routing decision instead of running the real green/red paths.
  def monitor(client:)
    sink = { green: [], red: [] }
    m = PipelineMonitor.allocate
    m.instance_variable_set(:@client, client)
    m.instance_variable_set(:@project_path, 'group/project')
    m.instance_variable_set(:@project_config, {})
    m.instance_variable_set(:@config, {})
    m.define_singleton_method(:log) { |*| nil }
    m.define_singleton_method(:log_error) { |*| nil }
    m.define_singleton_method(:handle_green) { |issue| sink[:green] << issue.issue_iid }
    m.define_singleton_method(:handle_red) { |issue, pipeline| sink[:red] << [issue.issue_iid, pipeline] }
    [m, sink]
  end

  def job(status:, allow_failure: false, name: 'test')
    { 'name' => name, 'stage' => 'test', 'status' => status, 'allow_failure' => allow_failure }
  end

  def dispatch(jobs: [], status: 'manual', client: nil)
    client ||= StubClient.new(jobs: jobs)
    m, sink = monitor(client: client)
    m.send(:dispatch_status, FakeIssue.new(15_894, 11_154), FakePipeline.new(215_229, status))
    [sink, client]
  end

  # --- the production case ------------------------------------------------

  def test_manual_with_green_blocking_jobs_is_treated_as_green
    jobs = [job(status: 'success', name: 'test'), job(status: 'success', name: 'rubocop_light'),
            job(status: 'manual', name: 'deploy_review'), job(status: 'manual', name: 'stop_review')]
    sink, = dispatch(jobs: jobs)

    assert_equal [15_894], sink[:green]
    assert_empty sink[:red]
  end

  def test_manual_with_a_failed_blocking_job_is_treated_as_red
    jobs = [job(status: 'success', name: 'rubocop_light'), job(status: 'failed', name: 'test'),
            job(status: 'manual', name: 'deploy_review')]
    sink, = dispatch(jobs: jobs)

    assert_empty sink[:green]
    assert_equal 1, sink[:red].size
    assert_equal 215_229, sink[:red].first.last.id, 'handle_red must receive the pipeline it triages'
  end

  # --- edge cases ---------------------------------------------------------

  # Consistent with dispatch_pipeline's "no pipeline found → treating as green".
  def test_manual_with_no_jobs_at_all_is_green
    sink, = dispatch(jobs: [])

    assert_equal [15_894], sink[:green]
  end

  def test_manual_with_only_manual_jobs_is_green
    sink, = dispatch(jobs: [job(status: 'manual', name: 'deploy_review')])

    assert_equal [15_894], sink[:green]
  end

  # GitLab itself says an allow_failure result does not gate the merge.
  def test_a_failed_allow_failure_job_does_not_make_it_red
    sink, = dispatch(jobs: [job(status: 'success'), job(status: 'failed', allow_failure: true, name: 'flaky')])

    assert_equal [15_894], sink[:green]
  end

  def test_an_allowed_failure_does_not_mask_a_real_one
    sink, = dispatch(jobs: [job(status: 'failed', allow_failure: true, name: 'flaky'),
                            job(status: 'failed', name: 'test')])

    assert_empty sink[:green]
    assert_equal 1, sink[:red].size
  end

  # A skipped pipeline is CI deciding nothing should run — the same absence of
  # verification dispatch_pipeline already treats as green when there is no
  # pipeline at all.
  def test_skipped_takes_the_same_path
    sink, = dispatch(jobs: [job(status: 'skipped')], status: 'skipped')

    assert_equal [15_894], sink[:green]
  end

  # --- what must NOT change ----------------------------------------------

  # An interrupted run has no verdict to read: its blocking jobs are `canceled`,
  # not `failed`, so the blocking-job rule would deliver a ticket whose tests
  # were killed mid-flight. Bounded generically by Autodev #53, not here.
  def test_canceled_still_waits_and_never_reads_the_jobs
    sink, client = dispatch(jobs: [job(status: 'canceled')], status: 'canceled')

    assert_empty sink[:green]
    assert_empty sink[:red]
    assert_equal 0, client.jobs_calls
  end

  # The one that must never regress: an API failure must not read as
  # "nothing failed → deliver".
  def test_an_unreachable_jobs_endpoint_delivers_nothing
    sink, = dispatch(client: StubClient.new(raise_error: true))

    assert_empty sink[:green]
    assert_empty sink[:red]
  end

  # --- the filter itself --------------------------------------------------

  def test_blocking_jobs_drops_allow_failure_and_unplayed_manual_jobs
    m, = monitor(client: StubClient.new)
    jobs = [job(status: 'success', name: 'test'), job(status: 'failed', allow_failure: true, name: 'flaky'),
            job(status: 'manual', name: 'deploy_review')]

    assert_equal ['test'], m.send(:blocking_jobs, jobs).map { |j| j['name'] }
  end

  # Fail safe: an absent allow_failure key reads as nil, which must count as
  # blocking rather than silently excusing the job.
  def test_a_job_without_an_allow_failure_key_is_blocking
    m, = monitor(client: StubClient.new)

    assert_equal 1, m.send(:blocking_jobs, [{ 'name' => 'test', 'status' => 'failed' }]).size
  end
end
```

- [ ] **Step 2: Run it and watch it fail for the right reason**

Run: `mise x ruby -- bundle exec rake test TEST=test/pipeline_monitor_manual_status_test.rb`

Expected: FAIL. `manual` and `skipped` currently land in the `else`, so every green/red expectation gets an empty sink; the two `blocking_jobs` tests get `NoMethodError`. `test_canceled_still_waits_and_never_reads_the_jobs` and `test_an_unreachable_jobs_endpoint_delivers_nothing` pass already — they pin behaviour that must survive, not behaviour to add.

---

### Task 2: The implementation

**Files:**
- Modify: `lib/autodev/pipeline_monitor/constants.rb`
- Modify: `lib/autodev/pipeline_monitor/api_helpers.rb`
- Modify: `lib/autodev/pipeline_monitor/job_classifier.rb`
- Create: `lib/autodev/pipeline_monitor/blocked_pipeline.rb`
- Modify: `lib/autodev/pipeline_monitor.rb`

**Interfaces:**
- Consumes: `GitlabHelpers.field`, `@client.pipeline_jobs`, the existing `handle_green` / `handle_red`.
- Produces: `dispatch_blocked(issue, pipeline, status)`, `blocking_jobs(jobs)`, `failed_blocking_jobs(jobs)`, `fetch_pipeline_jobs(pipeline)`.

- [ ] **Step 1: Constants**

In `lib/autodev/pipeline_monitor/constants.rb`, after `RUNNING_STATUSES`:

```ruby
  # Pipeline statuses that are terminal but inconclusive: GitLab will never move
  # them on its own, yet the roll-up is neither `success` nor `failed`. Resolved
  # by looking at the blocking jobs instead (Autodev #51). `canceled` is
  # deliberately NOT here — see the "No blocked state" decision in CLAUDE.md.
  BLOCKED_STATUSES = %w[manual skipped].freeze

  # Job statuses that cannot gate a merge. An unplayed `manual` job has no
  # result and will never acquire one without a human, which is exactly why
  # waiting on it is waiting forever.
  NON_BLOCKING_JOB_STATUSES = %w[manual].freeze
```

- [ ] **Step 2: `fetch_pipeline_jobs`**

In `lib/autodev/pipeline_monitor/api_helpers.rb`, above `fetch_failed_jobs`:

```ruby
    # The pipeline's full job list, or nil when GitLab could not be reached.
    #
    # nil, not [] — the distinction is the whole safety of the `manual` path
    # (Autodev #51): [] means "this pipeline genuinely has no jobs" and reads as
    # green, so an API error swallowed into [] would deliver a ticket nobody
    # verified. fetch_failed_jobs below can afford `[]` because its caller
    # already knows the pipeline is red.
    #
    # per_page: 100 without auto_paginate, matching fetch_failed_jobs and
    # DeployReview#find_deploy_review_job: no configured project has a
    # >100-job pipeline, and the three call sites should move together if one
    # appears.
    def fetch_pipeline_jobs(pipeline)
      @client.pipeline_jobs(@project_path, pipeline_id(pipeline), per_page: 100)
    rescue Gitlab::Error::ResponseError => e
      log_error "Failed to fetch pipeline jobs: #{e.message}"
      nil
    end
```

- [ ] **Step 3: The blocking filter**

In `lib/autodev/pipeline_monitor/job_classifier.rb`, inside the module (after `pre_triage` and its helpers, before `categorize_jobs!`):

```ruby
    # A job is blocking when its result gates the merge. Two exclusions
    # (Autodev #51): `allow_failure: true`, where GitLab itself says the result
    # does not count, and an unplayed `manual` job, which has no result at all.
    # Anything else — including `created` or `skipped` jobs sitting downstream
    # of a manual gate — counts, and is simply not failed.
    def blocking_jobs(jobs)
      jobs.reject { |job| non_blocking_job?(job) }
    end

    def non_blocking_job?(job)
      return true if GitlabHelpers.field(job, :allow_failure)

      NON_BLOCKING_JOB_STATUSES.include?(GitlabHelpers.field(job, :status).to_s)
    end

    def failed_blocking_jobs(jobs)
      blocking_jobs(jobs).select { |job| GitlabHelpers.field(job, :status).to_s == 'failed' }
    end
```

- [ ] **Step 4: The dispatch module**

Create `lib/autodev/pipeline_monitor/blocked_pipeline.rb`:

```ruby
# frozen_string_literal: true

class PipelineMonitor
  # Resolves a pipeline whose roll-up status is terminal but inconclusive
  # (`manual`, `skipped`) by looking at its jobs (Autodev #51).
  #
  # GitLab reports `manual` when everything that could run has run and what is
  # left needs a human to press play. On a project whose MR pipelines end with a
  # manual `deploy_review` that is the normal end state of a *green* MR — so
  # treating it as "wait and see" waits forever: nothing will ever change the
  # status, and stagnation detection is fed from handle_red only, so no bound
  # ever fires. Measured on powerpanne/core: one pipeline read 12 729 times in
  # 18 days, four finished tickets delivered by hand weeks later.
  #
  # The verdict is taken on the BLOCKING subset (see JobClassifier#blocking_jobs)
  # and asks "did anything that counts fail?", not "did everything succeed?" —
  # in a manual pipeline a blocking job can legitimately sit `created` or
  # `skipped` downstream of the gate, and demanding `success` from it would
  # reintroduce the same infinite wait one level down. Nothing can be *running*:
  # a running job would make the roll-up `running`.
  module BlockedPipeline
    private

    def dispatch_blocked(issue, pipeline, status)
      jobs = fetch_pipeline_jobs(pipeline)
      # nil = GitLab unreachable. Never read that as "nothing failed": an API
      # error must not be the reason a ticket ships. Retried next cycle.
      return log("Pipeline #{status} for MR !#{issue.mr_iid}: jobs unavailable, rechecking next poll") if jobs.nil?

      failed = failed_blocking_jobs(jobs)
      return blocked_red(issue, pipeline, status, failed) if failed.any?

      blocked_green(issue, status, blocking_jobs(jobs).size)
    end

    def blocked_red(issue, pipeline, status, failed)
      names = failed.map { |job| GitlabHelpers.field(job, :name) }.join(', ')
      log "Pipeline #{status} for MR !#{issue.mr_iid} but blocking job(s) failed (#{names}) → treating as red"
      handle_red(issue, pipeline)
    end

    def blocked_green(issue, status, count)
      log "Pipeline #{status} for MR !#{issue.mr_iid}: #{count} blocking job(s), none failed → treating as green"
      handle_green(issue)
    end
  end
end
```

- [ ] **Step 5: Wire it into `dispatch_status`**

In `lib/autodev/pipeline_monitor.rb`: add `require_relative 'pipeline_monitor/blocked_pipeline'` (after the `job_classifier` require) and `include BlockedPipeline` (after `include JobClassifier`), then extend the case:

```ruby
  def dispatch_status(issue, pipeline)
    status = GitlabHelpers.field(pipeline, :status)
    log "Pipeline ##{pipeline_id(pipeline)} status: #{status}"
    case status
    when *RUNNING_STATUSES  then log "Pipeline still running for MR !#{issue.mr_iid}, skipping"
    when 'success'          then handle_green(issue)
    when 'failed'           then handle_red(issue, pipeline)
    when *BLOCKED_STATUSES  then dispatch_blocked(issue, pipeline, status)
    # `canceled` and any future GitLab status land here: an interrupted run has
    # no verdict to read (its blocking jobs are `canceled`, not `failed`), and
    # unlike `manual` the wait usually resolves — a new pipeline supersedes it
    # and head_pipeline re-points. The unbounded tail is Autodev #53's job.
    else log "Pipeline #{status} for MR !#{issue.mr_iid}, skipping"
    end
  end
```

- [ ] **Step 6: Run the new tests**

Run: `mise x ruby -- bundle exec rake test TEST=test/pipeline_monitor_manual_status_test.rb`

Expected: PASS, 11 runs, 0 failures.

- [ ] **Step 7: Run the full suite**

Run: `mise x ruby -- bundle exec rake test`

Expected: 1361 runs, 0 failures, 0 errors. Quote the counts. Pay attention to `test/module_load_test.rb` — it enumerates the library files, so a new one may need listing there; if it fails, read what it asserts before changing anything.

- [ ] **Step 8: RuboCop**

Run:

```bash
mise x ruby -- rubocop lib/autodev/pipeline_monitor.rb lib/autodev/pipeline_monitor/constants.rb lib/autodev/pipeline_monitor/api_helpers.rb lib/autodev/pipeline_monitor/job_classifier.rb lib/autodev/pipeline_monitor/blocked_pipeline.rb test/pipeline_monitor_manual_status_test.rb
```

Expected: no offenses.

- [ ] **Step 9: Commit (tests + implementation together)**

```bash
git add lib/autodev/pipeline_monitor.rb lib/autodev/pipeline_monitor/ test/pipeline_monitor_manual_status_test.rb
git commit -F - <<'MSG'
fix: resolve a manual pipeline by its blocking jobs (Autodev #51)

GitLab reports `manual` when every job that could run has run and what is left
needs a human. dispatch_status knew three outcomes — running, success, failed —
so `manual` fell in the `else`: log a line, do nothing. The row stayed in
checking_pipeline, and nothing bounded the wait, because stagnation detection is
fed from handle_red only.

On a project whose MR pipelines end with a manual deploy_review, `manual` is the
NORMAL end state of a green MR, so every finished ticket parked forever. On
powerpanne/core: pipeline 215229 read 12 729 times in 18 days at one read per
two minutes, four tickets (#15894, #16237, #16258, #16341) finished with
review_count 0, never reviewed, never labelled done, eventually relabelled by
hand by three different humans between a day and four weeks later.

The roll-up cannot express "the jobs that gate the merge are green, the ones
that gate a deploy await a human"; the job list can. `manual` and `skipped` now
resolve on their blocking subset — allow_failure jobs and unplayed manual gates
excluded — asking "did anything that counts fail?" rather than "did everything
succeed?", since a blocking job may legitimately sit `created` or `skipped`
downstream of the gate and demanding success would rebuild the same infinite
wait one level down.

fetch_pipeline_jobs returns nil rather than [] on a GitLab error: [] reads as
green here, so swallowing an API failure would ship an unverified ticket.

`canceled` is unchanged and stays in the `else` — an interrupted run has no
verdict to read, and unlike `manual` a new pipeline usually supersedes it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
```

---

### Task 3: Docs

**Files:**
- Modify: `CHANGELOG.md` (`[Unreleased]`, into the existing `### Fixed` section)
- Modify: `CLAUDE.md` (`PipelineMonitor` section, Error Handling table, Key Design Decisions)
- Modify: `docs/usage/autodev-technical-usage.md` (decision matrix ~line 408, error catalog ~line 531)

**Interfaces:** consumes Task 2; produces nothing.

- [ ] **Step 1: `CHANGELOG.md`**

Append one bullet to `[Unreleased]`'s existing `### Fixed` section, in the register of the surrounding entries (problem → measurement → decision → what changed). It must carry: the `else` gap and the missing bound; the powerpanne numbers; the blocking-job rule and both its exclusions; why "nothing failed" rather than "everything succeeded"; `nil`-vs-`[]`; `skipped` joining and `canceled` not; and that no activity line was added.

- [ ] **Step 2: `CLAUDE.md`**

Three edits, all in the worktree's own `CLAUDE.md`:

1. **`### PipelineMonitor`** bullet list — replace `- **Canceled/skipped** → stay in `checking_pipeline` (manual intervention needed)` with two bullets: `manual`/`skipped` resolved on blocking jobs (green when none failed, red when one did), and `canceled` alone staying put.
2. **`## Error Handling`** table — the `Pipeline canceled/skipped` row narrows to `Pipeline canceled`, and a new row covers `Pipeline manual / skipped`.
3. **`## Key Design Decisions`**, the *No blocked state* bullet — it currently opens "Canceled pipelines keep the issue in `checking_pipeline` indefinitely". Keep that for `canceled`, and state that `manual`/`skipped` no longer do, with the one-line reason (a manual gate is the normal end of a green MR on some projects, so the wait was infinite by construction).

- [ ] **Step 3: `docs/usage/autodev-technical-usage.md`** (French)

1. Decision matrix (~line 408): replace `| Canceled / skipped | * | * | Reste en \`checking_pipeline\` (manuel) |` with a `Manual / skipped` row (verdict taken on the blocking jobs) and a `Canceled` row (unchanged).
2. Error catalog (~line 531): same split for `| Pipeline canceled / skipped |`.

Native technical French, matching the surrounding register. Do not touch the ASCII state diagram — it already reads `(running / canceled)` for the skip branch, which stays true.

- [ ] **Step 4: Full suite + RuboCop**

```bash
mise x ruby -- bundle exec rake test
mise x ruby -- rubocop
```

Expected: 0 failures / 0 errors; RuboCop at the 46-offense baseline across the same 9 untouched boilerplate files. Quote both.

- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md CLAUDE.md docs/usage/autodev-technical-usage.md
git commit -F - <<'MSG'
docs: only `canceled` still parks a ticket in checking_pipeline (Autodev #51)

CLAUDE.md documented "Canceled/skipped → stay in checking_pipeline (manual
intervention needed)" as a deliberate design decision, in three places, and the
French technical guide repeated it in two. Half of that is no longer true:
`manual` and `skipped` are now resolved on their blocking jobs.

The decision is narrowed rather than dropped, and now carries the comparison
that makes it a decision instead of an omission — an interrupted run has no
verdict to read, and unlike a manual gate it is usually superseded by a new
pipeline, so the residual unbounded tail is Autodev #53's to bound.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
```

---

## Verification

Before reporting the work done, confirm all three:

1. `mise x ruby -- bundle exec rake test` — 0 failures, 0 errors, 11 runs above the 1350 baseline. Quote the counts.
2. `mise x ruby -- rubocop` — 46 offenses, the same 9 pre-existing boilerplate files as `master`.
3. `git log --oneline master..HEAD` — three commits (the spec+plan, Task 2, Task 3).

Then hand back for review, and note in the report where this branch and Autodev #53 will meet at merge time: `dispatch_status` (this branch adds a `when` clause, #53 is expected to add a bound around the same dispatch), and the reading of `canceled` (this branch documents why it waits; #53 bounds that wait).
