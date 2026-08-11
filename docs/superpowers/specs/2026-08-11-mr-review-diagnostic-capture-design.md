# Capturing `mr-review`'s diagnostic (Autodev #49)

Date: 2026-08-11
Ticket: Skynet Autodev #49 — "mr-review échoue silencieusement : le diagnostic est
jeté, 3 MRs livrées sans revue"

Follows: `2026-08-10-mr-review-timeout-design.md` (Autodev #54), which rewrote the
method this design changes. The line fixed here survived that rewrite untouched.

## Problem

`PipelineMonitor::Reviewer#run_mr_review_command` keeps `stderr` and throws
`stdout` away:

```ruby
_, err, ok = run_with_timeout('mr-review', ['-H', mr_url], chdir: Dir.pwd,
                                                           timeout: mr_review_timeout)
return log('Review completed successfully') || true if ok

log_error "mr-review failed (non-fatal): #{err[0, 300]}"
```

In production `mr-review` fails **writing nothing to stderr**, so the one line
autodev emits is:

```
mr-review failed (non-fatal):
```

Measured over every retained log (`~/.autodev/log/production.log*`): **15
failures, 15 empty messages, zero exceptions**. Each failure took ≈1 s once the
`sleep 15` in `execute_mr_review` is subtracted — a crash at startup or a
rejected argument, not a timeout, and not the wedge #54 was about.

15 is `5 × 3`. Every one of those failures belongs to a ticket that exhausted
`REVIEW_FAILURE_THRESHOLD` and went out through `give_up_reviewing`:

| Issue | MR | Date |
|---|---|---|
| powerpanne/core#16415 | !11343 | 07/08 |
| powerpanne/core#16224 | !11187 | 06/08 |
| powerpanne/core#12852 | !11286 | 30/07 |

Three merge requests delivered with **no review at all**, and no way to find out
why: the only diagnostic `mr-review` produced was discarded at the call site, and
what autodev did keep — an empty string — is indistinguishable from a logging
bug. The root cause of the `mr-review` failure itself is therefore still unknown
and stays unknowable until this is fixed. That is what makes a two-line change
the highest-priority item on the ticket.

Two failure modes hide behind the same empty line, and today nothing tells them
apart:

- `mr-review` wrote its error to **stdout** (a `bundler/inline` script rejecting
  `-H`, an `OptionParser` usage dump, a `puts` + `exit 1` error path). This is the
  favourite: the run is ~1 s and stderr is empty.
- `mr-review` wrote **nothing anywhere** and died — `exec` failure, a signal, an
  interpreter that never started. Then even stdout is empty and the only signal
  left is the exit status, which `run_with_timeout` does not currently hand back.

A fix that only adds stdout would answer the first and leave the second exactly
as unknowable as it is now — one more release, one more production incident, one
more empty line. So the design covers both.

## Design

### 1. `run_with_timeout` hands back the exit status

`ProcessRunner#finish_process` already holds a `Process::Status` and reduces it to
`status.success?` before returning. The object is appended as a **fourth,
optional element**:

```ruby
[out, err, status.success?, status]
```

Ruby's destructuring makes this backwards compatible by construction: the two
`danger-claude` call sites (`out, err, ok = run_with_timeout(...)`) ignore the
extra element, and so do the test stubs that return three-element arrays — which
is why the reviewer must treat a `nil` status as "unavailable" rather than assume
it is there.

This is the one part of the change that touches shared code, so it is worth
saying why it is not deferred. Exit status is not decoration: `127` is
"command not found", `1` is a program that ran and refused, a `termsig` is a
process killed before it could speak. On the only observed failure shape —
nothing on either stream — it is the *entire* diagnostic. Adding stdout without
it would ship a fix that has a real chance of producing another empty line.

Formatting stays in `Reviewer` (the only consumer): `exit 127`, `killed by
signal 9`, or `exit status unavailable` when the element is absent.

### 2. The failure message reports both streams, legibly

```ruby
out, err, ok, status = run_with_timeout('mr-review', ['-H', mr_url],
                                        chdir: Dir.pwd, timeout: mr_review_timeout)
return log('Review completed successfully') || true if ok

log_error "mr-review failed (non-fatal): #{review_failure_diagnostic(out, err, status)}"
```

Four properties, each of which the current line gets wrong:

**Both streams, each labelled.** House style is already established by
`DangerClaudeRunner#dc_error_msg` and `ShellHelpers.run_cmd` —
`"…\nstdout: …\nstderr: …"`. `AppLogger#print_console` prints only the first line
to the console and writes the whole message to the log file, so a multi-line
message costs nothing on screen and keeps everything on disk.

**An empty stream says so.** `stdout: (empty)` rather than `stdout: `. A trailing
colon is exactly the ambiguity that made the 15 production lines useless.

**Both empty is an assertion, not an absence.** When neither stream produced
anything the message reads `exit 127, no output on stdout or stderr` — a positive
statement that the process died mute, on one line, which combined with the exit
status is a complete diagnosis. This is the single most important string in the
change: it is the currently observed situation, and it must never again look like
a bug in the logging.

**Truncation is bounded and announced.** 300 characters is roughly four lines —
enough to lose a usage dump's actual error. The cap becomes **2000 characters per
stream** (the failure path only; success logs nothing), and a truncated stream
ends with `… (N more characters)` so a reader knows there was more and how much.
Today's `[0, 300]` is silent about it.

Head kept, not tail: Ruby prints the exception line *first*
(`file:line:in 'meth': message (Class)`) and `OptionParser` prints usage first, so
the head is where the answer is for both hypotheses in §Problem. A head+tail split
was considered and rejected as unjustified complexity — if a real case ever needs
the tail, the truncation marker in the log will be the evidence that asks for it.

**Secrets are scrubbed.** `Redactor.scrub` is applied to the assembled
diagnostic. In production the logger on this path is `Autodev::JobLogger`, a
`SimpleDelegator` around Rails' logger — unlike `AppLogger`, it does **not**
scrub. We are about to start printing an external tool's raw output, and
`mr-review` handles the same GitLab PAT autodev does; a usage dump or an error
echoing the API URL is a plausible way for `glpat-…` to reach
`production.log`. The Redactor exists for precisely this class of sink (a PAT was
once found in cleartext in months-old logs, task #10).

### 3. The give-up path keeps the diagnostic on the row

`give_up_reviewing` is where a ticket's review is abandoned for good. It records
`needs_attention` / `review_failures_exhausted`, notifies GitLab and reassigns the
author — and stores nothing about *why*. The three tickets above carry that flag
today, and the only copy of their diagnostic was a log line that was empty and a
log file that rotates.

`ProcessRunner#record_output` already appends every run's stdout and stderr to
`@dc_stdout` / `@dc_stderr` — including `mr-review`'s, since #54 routed it
through the same wrapper. Those buffers are persisted onto the issue row by every
error handler in the codebase (`issues.dc_stdout` / `dc_stderr`, `text`
columns). The review give-up is the one terminal, human-facing outcome that does
not do it. So it does:

```ruby
Issue.where(id: issue.id).update_all(finished_at: Time.current, needs_attention: true,
                                     attention_reason: 'review_failures_exhausted',
                                     dc_stdout: @dc_stdout, dc_stderr: @dc_stderr)
```

Two keys on an `update_all` that already exists. A `PipelineMonitor` instance is
built per job, and the green branch of `check` performs no `danger-claude` call
before the review, so the buffers hold that cycle's `mr-review` run and nothing
else.

Scope note, stated rather than discovered: no view renders `dc_stdout` /
`dc_stderr` for a `done` row — the CLI's `--errors` display reads them only for
`status: error`. This change makes the diagnostic **durable and attached to the
ticket** (survives log rotation, queryable, in the same column every other
failure in the product uses); *surfacing* it in the web UI is a separate, larger
question about what a `needs_attention` row should show, and is recorded as a
follow-up rather than smuggled in here.

### 4. The failure threshold stays at 5 — the change is what it produces

The ticket asks for the threshold to be re-examined, on the grounds that it turns
a broken tool into unreviewed MRs flagged by nothing but `needs_attention`. The
re-examination says **do not move the number**, and the data is the reason.

*No value of the threshold would have saved those three MRs.* All 15 attempts
failed, deterministically, in ~1 s, from the first try. A threshold of 3 would
have delivered the same three unreviewed MRs two rounds earlier; a threshold of 1
would have delivered them immediately. The threshold's job is to absorb
*transient* failures (a GitLab 500, a rate limit, a flaky network) — and since
consecutive failures are separated by at least one poll cycle (300 s by default),
5 rounds buys ≈25 minutes of tolerance, which is a defensible transient window
and which nothing in the data contradicts.

*Lowering it has one real benefit and one real cost.* The benefit is wall time on
the slow failure path: since #54, a wedged `mr-review` burns up to
`mr_review_timeout` (3600 s) per round, so five rounds can hold a worker slot —
one of three — for five hours. The cost is that a genuinely flaky-but-recoverable
review gets fewer chances, and the outcome of giving up (`done`, `label_done`,
reassigned, `needs_attention`) is not cheap to undo. Nothing in the 15 failures
tells us which risk is larger, because all 15 were on the fast path. Picking a new
number here would be choosing against no data — the exact mistake #54's design
made, corrected, and wrote down.

*What was actually missing is the cause, not the count.* On 07/08 an operator
looking at the dashboard saw one flagged ticket; on 06/08 another; on 30/07 a
third. Three separate flags, no shared signal, and — because of the bug in §2 —
no cause on any of them. §§1–3 fix the cause. What remains unfixed is the
aggregation: `review_failure_count` is per-issue, so a globally broken
`mr-review` costs 5 rounds *per ticket* and produces N independent flags instead
of one alert saying the tool is down.

That aggregation is the change worth making next, and it is deliberately **not**
made here: it is cross-issue state, it needs a threshold and a window of its own,
its natural home is a `HealthReport` check counting recent
`attention_reason = 'review_failures_exhausted'` rows, and — like #54's timeout —
its parameters should be chosen against production numbers rather than invented.
It is recorded on the ticket as the follow-up.

One related oddity found while reading the path, worth writing down and not
fixing here: when `mr-review` is **not installed**, `execute_mr_review` logs
"skipping review" and returns `false`, which is counted as a *failure*. Five polls
later the ticket is given up with `review_failures_exhausted` — even though the
documented behaviour (`CLAUDE.md`, "Error Handling") is "warning at startup,
review step skipped". Not the cause of this incident (the empty message proves the
binary was found and ran), and changing it means deciding what a permanently
absent reviewer should do to delivery — a policy question, not a bug fix.

## Testing

TDD, one test per claim.

New `test/pipeline_monitor_review_diagnostic_test.rb`, reusing the `Harness`
pattern from `test/pipeline_monitor_review_heartbeat_test.rb` (mixes in
`DangerClaudeRunner` + `PipelineMonitor::Reviewer`, stubs `run_with_timeout`,
neuters `sleep`) with a `StubLogger` capturing the error lines:

- stdout reaches the message — the regression itself; this test fails on `master`.
- stderr still reaches the message — the behaviour that already worked must not be
  traded away for the one being added.
- an empty stream is marked `(empty)`, the other stream still shown.
- both empty produces the explicit "no output on stdout or stderr" sentence, and
  the message does not end in a colon (the shape of all 15 production lines).
- a stream longer than the cap is truncated **and** carries the `… (N more
  characters)` marker, with N correct.
- a `glpat-…` token in stdout comes out as `***`.
- the exit status appears: `exit 127` from a non-zero status, `killed by signal 9`
  from a signalled one, `exit status unavailable` when the stub returns the
  three-element tuple.
- the success path still returns `true` and logs no error.

`test/process_runner_test.rb` (today: `resolve_timeout` only) gains a real
subprocess test — the only honest way to pin the new element, and it doubles as
proof that stdout is captured at all:

- `/bin/sh -c 'printf hello; printf oops >&2; exit 3'` → `out == 'hello'`,
  `err == 'oops'`, `ok == false`, `status.exitstatus == 3`.
- a three-variable destructuring of the same call still binds correctly, pinning
  the backwards compatibility the two `danger-claude` callers rely on.

`test/pipeline_monitor_review_failure_test.rb` gains one case: after
`give_up_reviewing`, the row carries the buffers (§3).

The existing `test/pipeline_monitor_review_heartbeat_test.rb` must stay green
untouched — its stubs return three-element arrays, which is the compatibility
claim above, exercised for free.

## Docs

- `CHANGELOG.md` `[Unreleased]`.
- No user-facing string is added or changed: everything here goes to
  `production.log` and to two `text` columns, so `config/locales/` is untouched.
- No change to `docs/observability.md` or the usage guides — the operator-visible
  behaviour (a review failure, five of them, an attention flag) is identical; what
  changes is what the log line says.

## Constraints

CLAUDE.md: TDD, RuboCop green (`mise x ruby -- rubocop`, never edit
`.rubocop.yml`), Conventional Commits with the subject ending `(Autodev #49)`,
`CHANGELOG.md` `[Unreleased]` updated in the same pass, code and comments in
English.

## Out of scope

- **Reproducing the failure against the real MR !11343 and fixing `mr-review`
  itself.** That is the next step *after* this ships: it needs the diagnostic this
  change produces, and production access.
- **A cross-issue circuit breaker / aggregate alert for a globally broken
  `mr-review`** (§4). The right change, the wrong ticket.
- **Rendering `dc_stdout` / `dc_stderr` for a `done + needs_attention` row in the
  web UI** (§3).
- **Counting "mr-review not installed" as something other than a review failure**
  (§4).
- **The 11-day delay on #16415.** Not a bug: `labels_todo` is
  `["To do", "Development::ToDo"]` and the `autodev` label triggers nothing. It is
  a UI trap, and the arbitration (drop the label from the project, or add it to
  `labels_todo`) belongs to a human conversation with the requester, not to code.
