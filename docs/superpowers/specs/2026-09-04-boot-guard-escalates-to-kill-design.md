# The boot guard must not announce a stop it has not observed (Autodev #109)

Date: 2026-09-04
Ticket: Skynet Autodev #109 — "Le garde-fou de démarrage annonce un arrêt qu'il
ne vérifie pas : un TERM sans escalade laisse le fantôme en place, et le log dit
le contraire"
Follows: Autodev #92, which shipped `Autodev::BootGuard` in alpha 53. This is the
first real passage of that guard in production, and the half that did not work.

`BootGuard#reap` (`lib/autodev/boot_guard.rb:128`) sends one TERM, logs "Arrêt en
cours (TERM)", and moves to the next holder. It does not wait, does not retry,
and never verifies that the process is gone. The sentence is an assertion the
code does not support — the reproach the two neutral reviews of alpha 53 make to
this repository four times over (#73, #78, #87, #99), this time inside the fix
that was meant to close one of them.

## Problem

### What happened at the alpha 53 deployment, 03/09/2026 17h18

Two of the three things the guard does worked, and they must not be undone by
this fix.

It identified the orphan by its **process group**, exactly as designed — the rule
that replaced the `ppid == 1` filter after the alpha-53 neutral review. The
production log carries:

> Processus orphelin détecté au démarrage : rails-server (pid=1383), enfant d'un
> superviseur précédent dont le groupe de processus 1176 n'a plus de chef

And it did **not** refuse the boot, on a host where the container VM was holding
all three database paths at that instant. With the code as first written for #92,
this deployment would have been refused, in a loop under `KeepAlive: Crashed`.

The third thing failed. Forty minutes later the alpha-52 puma was still alive:

- pid 1383, ppid 1, pgid 1176 (the dead supervisor's group), up since 15h53
- RSS 151 MB — #92 estimated 60 MB, so two and a half times more
- three descriptors on the database, `autodev.db` (14u), `autodev.db-wal` (15u),
  `autodev.db-shm` (16u), open for writing

A manual KILL was needed. Immediately after it, `PRAGMA wal_checkpoint(PASSIVE)`
answered `0|322|322` — 322 pages checkpointed at once, which the ghost client had
been preventing. That is the harm #92 named, and it was real.

### The escalation exists five methods away, and cannot be reused as it stands

`Supervisor#shutdown_children` (`lib/autodev/supervisor.rb:104`) has the right
shape: `send_term`, a `TERM_GRACE_SECONDS` (10) bounded wait, then
`force_kill_stragglers`. The guard does not reuse it.

It cannot reuse it verbatim, and the reason is the whole design point of this
ticket. `Supervisor` works on **its own children**: `Child#alive?` asks
`Process.kill(0, pid)`, which works for any pid, but `force_kill_stragglers`
(`supervisor.rb:139`) ends with `Process.wait(child.pid)`, which raises `ECHILD`
on a foreign pid. A boot guard's orphan belongs to pid 1 — nobody here has to
reap it, and trying to would be an error.

So the *shape* is shareable and the *code* is not. What is common is: signal,
poll liveness until a deadline, escalate, answer what happened.

### Why the guard's own tests did not catch this

All six tests in `test/boot_guard_test.rb` inject `killer:` — a lambda that
records the pid and kills nothing. The escalation could not have been observed
by any of them, because no test ever had a process to observe. `Supervisor` has
exactly the test that was missing here ("child ignoring term is still killed
after the grace", `test/supervisor_test.rb`), against a real subprocess that
ignores SIGTERM. That asymmetry is why one of the two escalations is correct and
the other is a single unverified signal.

## Design

### 1. `Autodev::ProcessStopper` — the shape, on a bare pid

New file `lib/autodev/process_stopper.rb`. One entry point:

```
Autodev::ProcessStopper.stop(pid, grace:, alive:, killer:, sleeper:) -> Symbol
```

It answers exactly one of three verdicts:

- `:gone_on_term` — the process left within the grace after SIGTERM
- `:gone_on_kill` — it survived the grace, SIGKILL was sent, and it is gone
- `:alive` — it survived SIGKILL, or could not be signalled for a reason other
  than "already gone"

Liveness is `Process.kill(0, pid)`, the same question `Child#alive?` asks:
`ESRCH` is gone, `EPERM` is alive and someone else's. There is **no**
`Process.wait` anywhere in this module — the orphan is init's child, not ours,
and init reaps it. `Errno::ESRCH` on the signal itself is `:gone_on_term` /
`:gone_on_kill`, not an error: a process that died between two instructions is
the outcome we wanted.

`grace`, `alive`, `killer` and `sleeper` are keyword arguments with real
defaults, so the production call site passes only the pid, and the tests can
drive the clock without sleeping ten seconds.

**The grace defaults to 10 s, the same value as `Supervisor::TERM_GRACE_SECONDS`.**
It is declared in `ProcessStopper` as `DEFAULT_GRACE_SECONDS` rather than read
from `Supervisor`: a module on a bare pid must not depend on the supervisor, and
the dependency in that direction would have to be undone the moment section 2
goes the other way. The two declarations carry a comment naming each other, and
if `Supervisor` adopts the module (section 2) its constant becomes a reference to
this one — one value, in the direction that survives either outcome.

The grace is paid only when a ghost exists, which is a deployment that was
already going to leave one behind. A boot that finds nothing pays nothing.

### 2. Whether `Supervisor` adopts it

Instructed here rather than decided in advance, because refactoring code alpha 53
has just shipped is not free.

The acceptance criterion is mechanical: **`Supervisor` adopts `ProcessStopper`
only if `test/supervisor_test.rb` needs no edit at all.** `send_term` logs per
child and `force_kill_stragglers` must still `Process.wait` its own children, so
the adoption is only worth it if it comes out as a drop-in for the middle
(`wait_for_graceful_exit`). If it does not, `Supervisor` keeps its loop and gains
one comment naming `ProcessStopper` as the same shape on a foreign pid, so the
next reader finds both.

Either outcome is a valid end state for this ticket. What is not valid is a
partial migration that leaves two escalations that differ by accident.

### 3. Three outcomes, three sentences, and none of them anticipates

`reap` calls `ProcessStopper.stop` and logs on the verdict, after the fact:

- `:gone_on_term` → the orphan was found and stopped. Info-level.
- `:gone_on_kill` → found, ignored the TERM, killed after the grace. Warning,
  naming the pid and the grace — this is the case measured on 03/09, and it
  should be visible without being alarming.
- `:alive` → warning that names the pid, the command and the database path, and
  says explicitly that the boot is continuing with that process still holding the
  file.

The existing key `cli_boot_guard_reaped_orphan` is rewritten: it currently ends
with "Arrêt en cours (TERM)", which is the false claim. It becomes the discovery
sentence only — what was found and why it is ours — and the outcome is a second,
separate line. Splitting discovery from outcome is what makes each sentence true
on its own; a single sentence would have to be written before the result is
known, which is how this defect was born.

Four keys, `fr` and `en`, identical placeholders:

- `cli_boot_guard_orphan_found` (rewritten from `cli_boot_guard_reaped_orphan`)
- `cli_boot_guard_orphan_stopped_term`
- `cli_boot_guard_orphan_stopped_kill`
- `cli_boot_guard_orphan_survived`

### 4. What a boot does with an orphan that survives SIGKILL

**It warns, names the pid, and continues.** Strict mode (`AUTODEV_BOOT_GUARD_STRICT=1`)
raises `ConfigError` instead.

This is the asymmetry the guard already reasons from, applied to one more case:
a false refusal is a total outage repeated on every launchd restart, a false pass
is one ghost process. Nothing about a process surviving SIGKILL changes that
arithmetic — it makes the process *more* remarkable, not the outage *less*
costly. Production ran correctly for forty minutes on 03/09 with the ghost beside
it, which is the empirical half of the same argument.

Strict mode is where the refusal belongs, and this is the first case where strict
mode has a genuine use: an operator investigating by hand wants the boot to stop
in front of a process nothing can kill. The `@strict` branch already exists in
`handle`; this adds the second call site.

### 5. Why that puma did not honour its TERM

Instructed, not blocking, and it does not gate the fix.

The hypothesis is the simplest one available: a graceful shutdown waiting for
something that will never arrive. The process had no listener — the new puma had
taken the port — and its supervisor was dead. If that is what it is, SIGKILL is
the only exit and section 1 is the whole answer. The finding goes in the changelog
either way; if it turns out to be something else, that is a new ticket, not a
widening of this one.

## Testing

TDD, and every test below must be verified red against the fix removed —
the alpha-53 review found four fixes in this repository with no test capable of
failing, and one of them was in this very file.

1. **A real subprocess that ignores SIGTERM is killed after the grace.** The test
   `test/supervisor_test.rb` already has for the supervisor, now for the guard:
   spawn a child that traps and ignores TERM, drive `ProcessStopper.stop` with a
   short injected grace, assert `:gone_on_kill` and assert the pid is really gone
   with `Process.kill(0, pid)` raising `ESRCH`. This is the test whose absence let
   the defect through.
2. **A process that honours TERM gives `:gone_on_term`,** and no KILL is sent —
   asserted through a `killer` spy that records every signal, so "we did not
   escalate unnecessarily" is a fact and not an assumption.
3. **A process that survives KILL gives `:alive`,** driven with an injected
   `alive` that keeps answering true, and the boot **proceeds**: `call` returns
   normally and the warning naming the pid was logged.
4. **Strict mode raises on `:alive`,** and only on `:alive` — a
   `:gone_on_kill` under strict mode must not raise, or an operator investigating
   by hand could never boot after a successful reap.
5. **The three outcome sentences are distinct and each is logged only on its own
   verdict.** Guards against the shape of the original defect returning as a
   sentence written before the result.
6. **The i18n key scan** (Autodev #68/#73) must read all four new keys off their
   call sites; `foreign_message`'s existing ternary is the precedent for writing
   the literals where the scan can see them.

## Docs and i18n

- Four keys in `config/locales/cli.fr.yml` and `config/locales/cli.en.yml`, same
  placeholders in both.
- `CLAUDE.md`'s topology section describes the boot guard's behaviour; the TERM
  sentence there becomes the escalation, and the "what happens to an unidentified
  holder" paragraph gains the surviving-orphan case.
- `CHANGELOG.md` `[Unreleased]`, with the 03/09 measurement (151 MB, three
  descriptors, `0|322|322`) since it is what makes the ticket's harm concrete.

## Constraints

TDD. RuboCop green on the whole tree (`mise x ruby -- rubocop`). Conventional
Commits. `CHANGELOG.md` `[Unreleased]` in the same pass. i18n `fr` **and** `en`
for every visible string.

## Out of scope

- The cause of the supervisor's death. #92 put it out of scope and nothing here
  changes that.
- A health card for a stale process. Named in #92's out-of-scope list, still out.
- `ProcessRunner`'s `pgroup` option, which exists so a timeout can kill a whole
  subprocess tree. Untouched, as in #92.

## Lot alpha 54 — what the other two branches touch

Three branches, integrated into `integration/alpha54` before master. This one is
the only one under `lib/autodev/` outside the pipeline monitor.

- `fix/110-111-102-the-pass-writes-what-it-selects-on`:
  `app/services/autodev/poll_dispatcher.rb`, `app/jobs/issue_process_job.rb`,
  `lib/autodev/pipeline_monitor/infra_recheck.rb`.
- `fix/105-a-conflicted-mr-is-not-eligible`:
  `app/services/autodev/review_arrears_sweep.rb`.

No code file is shared. The only expected conflicts in the integration branch are
positional: `CHANGELOG.md` `[Unreleased]` and the locale files, three independent
blocks each.
