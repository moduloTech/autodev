# Plan — the poll has its own worker (Autodev #139)

Spec: `docs/superpowers/specs/2026-10-21-the-poll-has-its-own-worker-design.md`.
One lane (four config lines and three tests); no parallel dispatch.

## Contract

- Queue name `poll` (`AutodevPollJob.queue_name == 'poll'`).
- `config/recurring.yml` `autodev_poll.queue: poll` in `default` (hence production).
- `config/queue.yml` workers: `{queues: [default, solid_queue_recurring], threads: AUTODEV_MAX_WORKERS, processes: 1, polling_interval: 0.1}`,
  `{queues: [poll], threads: 1, processes: 1, polling_interval: 1}`.
- `config/database.yml`: `primary_default.pool = max(10, N + 2)`, `queue_default.pool = max(6, N + 3)`,
  `N = ENV.fetch('AUTODEV_MAX_WORKERS', 3).to_i`.

## Steps

1. **Red**: `test/the_poll_is_not_starved_test.rb` — real Solid Queue workers (async) from
   `SolidQueue::Configuration(config_file: config/queue.yml, only_work: true)`, on a tmp SQLite file
   with `db/queue_migrate` applied through `SolidQueue::Record`'s connection; stand-in job classes
   whose `queue_as` reads `IssueProcessJob.queue_name` / `AutodevPollJob.queue_name`; the poll enqueued
   through `SolidQueue::RecurringTask.from_configuration('autodev_poll', …)` with the production
   recurring entry (class swapped for the stand-in). Assert: 3 long jobs running, latch held, poll runs.
   Restore `SolidQueue::Record`'s connection in teardown.
2. **Red**: `test/queues_are_served_test.rb` — every `queue_as` of `app/jobs/*.rb` (constantized,
   `queue_name`), every recurring task of every env (`queue` else class's `queue_name`) is served by
   some worker of every env of `queue.yml` (exact, `*`, or `prefix*`). Plus: the poll is served by a
   worker that serves nothing else, and no worker serving `IssueProcessJob`'s queue serves the poll's.
3. **Red**: `test/connection_pools_fit_worker_threads_test.rb` — for N in `NumericSettings::SPECS['max_workers']`
   range, evaluate ERB of `database.yml` and `queue.yml` with `AUTODEV_MAX_WORKERS=N`; assert Solid
   Queue's `estimated_number_of_threads` ≤ queue pool, N ≤ primary pool, for each env.
4. **Green**: the four config edits + `queue_as :poll`.
5. After the plan review: `Autodev::QueuePatterns.serves?` (Solid Queue's queue-matching rule, shared by
   the test and the health card); the `workers` card goes `down` per unserved queue
   (`test/services/health_report_workers_test.rb`); `test/queue_database_on_file.rb` (queue schema on a
   tmp file, only Solid Queue's pool disconnected on restore).
6. Docs: `CLAUDE.md` (topology, concurrency sentences), `config/queue.yml` and `database.yml` comments,
   `docs/usage/autodev-technical-usage.md` (`AUTODEV_MAX_WORKERS` rows), `CHANGELOG.md` `[Unreleased]`.
