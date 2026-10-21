# The poll has its own worker (Autodev #139)

## Problem

On 15/10/2026 production's `/healthz` went `down` on the `poller` check three
times (02:58 → 03:20, 08:00 → 08:43, 13:00 → 13:45 UTC). The service had not
restarted: the scheduler enqueued an `AutodevPollJob` every two minutes, and
none ran until the 3 worker threads were released by the `IssueProcessJob`s the
10:00 poll had itself enqueued (15325: 24 min, 10539: 27 min, 15673: 25 min,
then five more at 4–15 min each). Then the 21 queued polls ran back to back.
Every gap began at the return of the Claude quota, the cycle that enqueues the
most work. Beyond the 503, a label handover posted at 08:00:25 on A#163
(PP#16190) was only acted on at 13:44:42 (ticket comment of 15/10).

Cause: `config/queue.yml` declares one worker, `queues: "*"`, `threads:
AUTODEV_MAX_WORKERS` (3), and every job is `queue_as :default` — and
`config/recurring.yml` additionally pins `autodev_poll` to `queue: default`.
Solid Queue claims ready executions in `(priority, job_id)` order inside a
queue, so each freed thread takes the oldest `IssueProcessJob` before the
younger poll. The poll waits behind the work it enqueued.

A priority alone would not do (ticket): the first thread freed at 10:24, a
24-minute gap, past `poll_stale_after` (900 s).

## Decision

1. `AutodevPollJob` is `queue_as :poll`, and `config/recurring.yml`'s
   `autodev_poll` entry says `queue: poll`. Both, because a recurring task's
   `queue:` **overrides** the class's `queue_as` (`SolidQueue::RecurringTask`
   stores it as `queue_name` and enqueues with `set(queue:)`), and the scheduler
   is the only production enqueuer of the poll. The static task row is upserted
   at every scheduler boot (`RecurringSchedule#persist_static_tasks`), so the
   change reaches the existing queue database without a migration.
2. `config/queue.yml` declares two workers:
   - `queues: [default, solid_queue_recurring]`, `threads: AUTODEV_MAX_WORKERS`
     — every other job;
   - `queues: [poll]`, `threads: 1`, `polling_interval: 1`.
   The first no longer uses `"*"`, which would also claim polls. An explicit
   list means a job on a queue nobody serves would wait forever, so
   `test/queues_are_served_test.rb` derives every queue a job can land on —
   every `queue_as` in `app/jobs`, every recurring task of every environment
   (its `queue:` else its class's queue) — and asserts each one is served by a
   worker of every environment.
3. Only the poll moves (owner). `SyncGitlabMembershipsJob`,
   `RefreshProjectBriefingsJob` (a clone + a danger-claude call, minutes),
   `LogJanitorJob`, `PruneActivityEventsJob` and `ReapFailedJobsJob` stay on
   `default` and keep sharing its threads with `IssueProcessJob`. The
   `clear_solid_queue_finished_jobs` entry is a `command:` task, which Solid
   Queue runs as its own `RecurringJob` — `queue_as :solid_queue_recurring`,
   a queue no file of this repository named. Under `"*"` that was invisible;
   under `[default]` the job would have waited for ever (found by the plan
   review, verified by enqueuing it). The first worker therefore lists
   `solid_queue_recurring` too, and the served-queues test covers the
   framework jobs the app loads (Active Storage, Turbo) as well.

## Consequences

- **Polls are serialised.** One thread means at most one poll at a time. Before,
  up to three could run concurrently after a gap (the 21 polls of 15/10 all
  ran within one minute on three threads), each enqueueing the same
  population. A poll longer than the
  interval delays the next one instead of overlapping it. Measured on the
  development copy of production (`activity_events`, `kind = 'poller'`,
  `cycle_complete`): since July, 30 618 cycles, mean 6–7 s, 11 longer than
  120 s (max 2 039 s). June had 4 489 cycles of ~125 s; none since
  July. A backlog after a long cycle drains at ~7 s a poll.
- **One more process.** In fork mode every worker entry is its own process
  (`processes: 1`), with its own pools; `bin/jobs start` now forks dispatcher,
  scheduler and two workers. Idle cost: one `ready_executions` query per second
  on the queue file (the `default` worker keeps 0.1 s).
- **The `workers` health card asks per queue.** It was "at least one alive
  worker"; with two worker processes the poll worker alone would read healthy
  while no ticket is processed. `HealthReport#unserved_queues` reads each alive
  worker's recorded `queues` metadata and the card goes `down` naming the
  queue (`IssueProcessJob`'s or the poll's) no alive worker serves.
- **The `IssueProcessJob` concurrency cap is unchanged**: `AUTODEV_MAX_WORKERS`
  threads on `default`. The poll's thread is in addition to it.

## Connection pools

Solid Queue refuses to start (`Configuration#ensure_correctly_sized_thread_pool`,
then `abort` in `Supervisor.start`) when the `queue` pool is smaller than
`max(threads of any worker) + 2` (the worker's own loop and its heartbeat). The
check is per process, which matches fork mode: each worker owns its pool.

Measured with `SolidQueue::Configuration#valid?` against the committed
`database.yml` (pool 6), `RAILS_ENV=test`:

| `AUTODEV_MAX_WORKERS` | required | pool | valid |
|---|---|---|---|
| 3 | 5 | 6 | yes |
| 4 | 6 | 6 | yes |
| 5 | 7 | 6 | **no** — "configured to use 7 threads but the database connection pool is 6" |
| 64 | 66 | 6 | **no** |

The new worker does not change the arithmetic (`max(N, 1) + 2`). But
`max_workers` is declared `[1, 64]` in `NumericSettings::SPECS`, and every value
from 5 up makes the `solid-queue` child abort at boot, which makes the
supervisor tear everything down (`KeepAlive: Crashed` then restarts it in a
loop). That is a defect independent of this ticket, measured while answering
the owner's question, so the pools are now derived from the same variable:

- `queue`: `max(6, N + 3)` — Solid Queue's `N + 2`, plus the one slot of
  headroom the comment already reserved;
- `primary`: `max(10, N + 2)` — each of the `N` job threads checks out a
  primary connection while it performs; with pool 10 and `N > 10` the
  eleventh would wait `checkout_timeout` and raise
  `ActiveRecord::ConnectionTimeoutError` mid-job. Fixing the queue pool alone
  would have turned a loud boot refusal into silent runtime failures.

Not counted: `IssueProcessor::ParallelRunner` starts threads inside one job
(two for a split implementation, one per planned task otherwise) which can
check out a primary connection of their own. That is true today with pool 10
and N = 3 and is not changed here; the floor of 10 keeps its headroom.

Both stay at 6 and 10 for `N ≤ 3`/`N ≤ 8`, i.e. production is unchanged.
`test/connection_pools_fit_worker_threads_test.rb` evaluates `database.yml`
and `queue.yml` under every `N` of the declared range and asserts Solid
Queue's own `estimated_number_of_threads` fits.

## Proof

`test/the_poll_is_not_starved_test.rb` runs real Solid Queue workers in-process
(async mode), built from `config/queue.yml` through `SolidQueue::Configuration`,
on a throwaway SQLite file carrying the queue schema (`test/queue_database_on_file.rb`). Five long jobs on
`IssueProcessJob`'s queue block on a latch; once three of them hold every
`default` thread, a poll is enqueued **through the `autodev_poll` recurring task
of `config/recurring.yml`** (queue resolved exactly as the scheduler does). The
test asserts the poll runs while the latch is still held. On the start SHA the
same script reports `[[:long, 0], [:long, 2], [:long, 1]]` and the poll never
runs: the starvation, reproduced.

## Out of scope

The ticket's comment raises a second strand: `IssueProcessJob#perform` checks
only `DISPATCHED_FROM` (the row's status), so a job enqueued before a human
gesture acts on a stale state until the poll closes the row. A dedicated poll
worker shrinks that window to one poll interval but does not close it. The
proposed remedy (asking `ExternalState#not_ours?` before Claude-consuming
actions, one GitLab read per job) is a decision the comment leaves open; it is
not done here.

## Owner may reverse

- **Pools derived from `AUTODEV_MAX_WORKERS`.** Alternative: lower
  `max_workers`' ceiling to 4 in `NumericSettings::SPECS`, the largest value
  the fixed pool 6 accepts. On the motivating case (production at 3) both are
  identical.
- **`polling_interval: 1` on the poll worker.** Alternative: 0.1 s like the
  default worker. A poll arrives every 120 s; 0.9 s of extra latency is
  invisible, ten idle queries a second are not free on SQLite.
- **Only the poll moves** (owner's decision). Alternative: the short recurring
  jobs on `poll` too; `RefreshProjectBriefingsJob` must not, since its clone +
  danger-claude call would delay a poll by minutes.
