# The post-completion hook runs once per delivery, and says so when it fails

Autodev #114 and Autodev #94, one lot (triage of 23/09/2026: same pass, latent
for the same reason, and #94's question — what a failure should produce — needs
#114's answer — how many times the command can run).

## Measurements

| Fact | Source |
|---|---|
| Production `poll_interval` is 120 s | `ssh bobette … grep poll_interval ~/.autodev/config.yml` → `poll_interval: 120` |
| No production project declares `post_completion` | `select count(*) from projects where post_completion …` on bobette → `0` |
| `dispatch_done_unassigned`'s population on the dev copy: 32 rows (30 powerpanne, 2 fast) | `select project_path, count(*) from issues where status='done' and needs_attention=0 and mr_iid is not null group by 1` |
| The only writer of `post_completion_error` is `store_pc_error`; nothing ever clears it | `lib/autodev/pipeline_monitor/post_completion.rb:86`; recon over `app/`, `lib/` |
| `/healthz` already carries a `warn` for a set `post_completion_error` (HTTP 200, by design) | `app/services/autodev/health_report.rb:312`, `app/controllers/monitoring_controller.rb:32-38` |
| The delivered-review tab and `--errors` already list it | `app/helpers/web/issues_filter.rb:43`, `lib/autodev/dashboard/error_display.rb:42` |
| A failed clone raises `GitError` out of `perform_post_completion` before `post_completion_done!` | `lib/autodev/repo_operations.rb:41` → `ShellHelpers.run_cmd` raises; `app/jobs/issue_process_job.rb:173-181` has no rescue |
| Baseline suite | `bundle exec rake test` → 2777 runs, 0 failures |

Two statements of #94 are corrected by these readings: the health endpoint is
not green (its body carries a `warn`; only the HTTP status stays 200, which is
the documented contract for `warn`), and the errors tab is not the only trace.
What *is* missing is the one sink that reaches the person who now owns the
ticket: GitLab. #94 also missed a fourth failure mode, worse than the three it
names — a failed clone leaves the row in `running_post_completion`, the job
fails, and no error is written at all.

## Decisions (owner, 28/09/2026)

### 1. A reservation at enqueue (#114)

New column `issues.post_completion_dispatched_at` (datetime, NULL = this
delivery's hook has not been dispatched). `dispatch_done_unassigned` selects
`post_completion_dispatched_at IS NULL`; `check_post_completion_needed`, after
its two GitLab gates, reserves the row with a compare-and-set `update_all`
(`id`, `status: 'done'`, `needs_attention: false`,
`post_completion_dispatched_at: nil` → `Time.current`) and enqueues only when
that update touched a row. This is CLAUDE.md's rule — *a pass writes the state
it selects on; the work it triggers does not* — and the shape
`reserve_infra_recheck?` already has (Autodev #110).

Rejected: a trace written by the job at completion. Between the enqueue and the
job's end the row still looks undispatched, so a command longer than one poll
interval (120 s in production; `post_completion_timeout` defaults to 300 s)
runs twice.

A lost job does not redeploy: its reservation stands. That is already the rule
for an interrupted `running_post_completion` (reset to `done` on startup, not
re-executed — CLAUDE.md Error Handling).

The stamp is cleared, together with `post_completion_error`, wherever a row goes
back into work — the three writers that take a row out of `done`/`error` into a
working state:

- `ResumeHandler#reenter_via_pipeline_check` (todo label reposed, MR open);
- `ResumeHandler#reenter_via_reimplementation` (todo label reposed, no MR);
- `Issue.reset_for_retry!` (dashboard Reset, `--reset`, error recovery, stalled
  revival of pre-MR states).

A new delivery is a new deploy; a new delivery also gets a new verdict, so the
previous one's error must not survive it.

A restart does not lift it: `revive_stalled!` and `recover_on_startup!` return
an interrupted `running_post_completion` to `done` with its stamp. And the job
runs only on a row that still carries a reservation (plan review): `DISPATCHED_FROM`
reads the status alone, so a job queued across a reentry and a second delivery
would otherwise deploy that delivery, and the next cycle would reserve and deploy
it again.

Review round (adversarial, neutral, concurrency): presence of a stamp is not
enough — the job carries the stamp it was reserved under (epoch seconds) and
runs only when the row holds that one, because the held job may also run after
the next cycle re-reserved; `limits_concurrency` keeps one key FIFO only while
its one-hour semaphore lives. An enqueue that raises lifts the stamp (the job is
in the queue database, the stamp in the primary). The failure write and its
comment are conditional on `running_post_completion`, so a Reset mid-hook keeps
the old failure off the reset row. An empty command and a NUL byte are
`ArgumentError`s out of `Process.spawn` and take the same sink.

Not backfilled. Every unstamped row the pass selects is a delivery whose hook
has not run, which is exactly the population the pass selects today; the
difference is that it now selects each one once.

### 2. A GitLab comment on failure (#94)

Every failure path of `run_post_completion` — invalid config, clone failure,
a command that cannot start (`Errno::ENOENT` / `EACCES` out of `Process.spawn`,
plan review), non-zero exit, a signal (no exit code, plan review), timeout —
goes through `store_pc_error`, which now also posts one
localized comment on the ticket: which command, what happened (exit code /
timeout / clone / config), that the delivery stands and the MR is untouched,
that the command will not be re-run, where the output is (the dashboard), and
how to replay it (repose the todo label). No stdout/stderr in the comment: a
deploy script's output is not something to publish on a ticket; the command
itself is passed through `Redactor.scrub`.

Rejected: `needs_attention` — that flag means "given up", it would put a
delivered row into the give-up population (`UntouchedSinceGiveup`, the audits)
and remove it from the hook's own population; #94 names this lie itself.
Rejected: a windowed health card — `check_issues_error` already warns.

### 3. One attempt per delivery

No automatic retry. Follows from decision 1: the reservation stands whether the
command succeeded or not. The comment says how to replay.

### 4. The transition stays unconditional (#94 item 3)

`post_completion_done!` is fired whatever the command's outcome: a deploy that
fails does not undo a merge-ready delivery. Written as a decision in the job,
and made to hold on a crash too (`ensure`), so a raise inside the hook — the
clone case above, or an unexpected error — cannot leave the row in
`running_post_completion` until the next restart.

### 5. The neighbourhood (#94 item 4) — no change

14 subprocess launch sites in `app/`, `lib/`, `bin/`. Three pass
`DangerClaudeRunner::CLEAN_ENV`: `ProcessRunner#spawn_process`
(`lib/autodev/process_runner.rb:58`), `UsageProbeSpawn`
(`lib/autodev/usage_probe_spawn.rb:57`), and the post-completion spawn
(`lib/autodev/pipeline_monitor/post_completion.rb:40`). The other eleven run
`git`, `docker`, `lsof`, `ps`, `which`, Chrome, and the supervisor's own
children (with their own `supervisor_env`): none of them is an arbitrary
external Ruby tool, and each already fails loudly (`run_cmd` raises, the
others are read by their callers). None needs the signal this lot adds.

## Out of scope

- The pass still reads GitLab twice per unstamped `done` row per cycle,
  including rows whose MR is merged (they are never stamped, because they are
  never dispatched). Unchanged from today, and only when a project configures
  the hook.
- The content of `post_completion_error` (stdout/stderr, 1000 chars each) in the
  dashboard is unchanged.
