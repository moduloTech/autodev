# A supervisor that dies must take its children, and be able to say it died (Autodev #92)

Date: 2026-09-03
Ticket: Skynet Autodev #92 — "Un déploiement laisse vivre le serveur web de la
version précédente, avec une connexion en écriture sur la base de production"

**The mechanism the ticket proposes is refuted, and the real one is both wider
and simpler.** It is not the process group, and it is not per deployment: it is
that `Supervisor#run` has no `ensure`, so any abrupt end leaves behind every
child it has already spawned — and on the production log, **39 of 63 boots ended
that way**.

## Problem

### The process-group hypothesis is wrong

The ticket supposes the supervisor spawns its children into a new process group,
so a signal to the supervisor's group misses them. It does not:

```ruby
# lib/autodev/supervisor.rb:143
def default_spawn(env, command)
  Process.spawn(env, *command)
end
```

No `pgroup:`. That option lives in `ProcessRunner#spawn_process`, for the
danger-claude and mr-review subprocesses, where it buys the ability to kill a
whole tree on timeout without taking the worker with it — a different concern,
untouched by this ticket. Production confirms it (03/09, `ps -o pid,ppid,pgid`):

```
 1176    1 1176  ruby .../autodev              ← supervisor
 1383 1176 1176  puma 6.6.1 (tcp://0.0.0.0:4567)
 1384 1176 1176  solid-queue-fork-supervisor: supervising 1401, 1402, 1403
```

One process group, `1176`, for everything, and puma is a **direct** child — so
the supervisor's `Process.kill('TERM', child.pid)` reaches it with nothing in
between.

### The shutdown path is correct, and it is simply not always reached

`shutdown_children` TERMs each live child by pid, waits `TERM_GRACE_SECONDS`
(10), then KILLs the stragglers. Read on its own it is right. The defect is one
level up:

```ruby
# lib/autodev/supervisor.rb:35
def run
  trap_signals
  spawn_all
  wait_loop
  shutdown_children
end
```

There is no `ensure`. Anything that ends this method early — an exception in
`spawn_all` after the first child, an exception out of `wait_loop`, a signal the
trap does not cover — leaves every already-spawned child running, and the
supervisor exits without a word about them.

`KeepAlive: Crashed` in the LaunchAgent plist is what makes that permanent:
launchd restarts the supervisor when its main process dies, and restarting a job
is not stopping it, so launchd does **not** kill the process group. The children
of the dead supervisor keep running and are reparented to pid 1 — exactly the
`PPID 1` puma the ticket measured.

### Measured on the production log

`~/.autodev/log/autodev-stdout.log` holds 134 supervisor lines, and they account
for themselves exactly:

| line | count |
|---|---|
| `spawned rails-server` | **63** |
| `spawned solid-queue` | **24** |
| `stopping rails-server` | **24** |
| `stopping solid-queue` | 23 |
| `force-killing … after 10s grace` | **0** |

So **39 boots produced a `rails-server` spawn and no further supervisor line at
all** — no second spawn, no shutdown. Every boot that reached the second spawn
also shut down cleanly, 24 for 24. The failure is localised: it is the interval
between the first child and the second.

Two independent observations agree on that interval. The ghost the ticket found
on 01/09 was a **puma alone** — no orphaned queue supervisor beside it — which is
what one expects if the supervisor died before `solid-queue` was ever spawned.

Zero `force-killing` also settles a sub-question: the 10-second grace has never
had to escalate, so a child ignoring TERM is not the story. And there is no
`Address already in use` anywhere in the stderr, so the tempting cascade — an
orphan holding port 4567 makes the next puma fail to bind — did not happen
either.

### What is not established, and the instrument that is missing

Why those 39 boots ended there. Two readings survive, and the evidence cannot
separate them:

* the supervisor died **between the two `Process.spawn` calls** — microseconds
  apart, so only an external signal or a raise inside the second spawn;
* it died **later**, and its buffered stdout was lost.

The second is live because the supervisor's lifecycle log is block-buffered:
`AppLogger#print_console` writes with `$stdout.puts`
(`lib/autodev/logger.rb:55`) and nothing sets `$stdout.sync`. Only the JSONL
files get `sync = true` (`:118`), and the supervisor's logger is constructed
without a log directory (`bin/autodev:457`), so on production there are no JSONL
files at all — checked: `~/.autodev/log/` holds only the launchd captures and
the Rails log.

**That diagnostic gap is itself a defect.** A supervisor whose lifecycle log is
buffered cannot report its own abrupt death, which is why a leak that has
happened 39 times has no account of a single occurrence.

### What the ghost costs

The process measured on 01/09 had been running four days and three hours, from
the exact minute of the alpha-49 deployment. It held the database file, its WAL
and its shared-memory file open **for writing** on three descriptors, at 60 MB
resident out of ~700 MB for all of autodev.

Without a listener it serves no traffic, so the practical risk is low. But a
SQLite WAL held open by a ghost client is precisely what stops a checkpoint from
completing, and the count grows by one process and 60 MB every time this
happens — which, on the numbers above, is more often than not.

## Design

### 1. `run` gets an `ensure`

```ruby
def run
  trap_signals
  spawn_all
  wait_loop
ensure
  shutdown_children
end
```

`shutdown_children` is already idempotent — `send_term` skips a child that is
not `alive?`, and `force_kill_stragglers` rescues `ESRCH`/`ECHILD` — so running
it on a path that has already run it is harmless, and running it after a partial
`spawn_all` stops exactly the children that exist.

This is the whole fix for the exception reading, and it is correct under the
buffering reading too: whatever ends `run` short of a signal, the children go
with it.

### 2. A signal the trap does not cover cannot be answered in-process

`SIGKILL` leaves nothing to run, so no code in the supervisor can help. Two
things are worth doing anyway, and neither is speculative:

**A boot guard, acting only on what it can positively identify.** At startup,
before spawning anything, look for a process that is *ours*: an autodev rails
server or queue supervisor, reparented to pid 1, holding our database file. For
one of those — a child of a previous supervisor, recognised as such — terminate
it, and log that it did. For anything else holding the file, **refuse to start**
and say what was found: the ticket's ruling that an unrecognised process deserves
a human, kept for the case where it applies.

The distinction matters because a blanket refusal is not safe here either: with
`KeepAlive: Crashed`, refusing on every restart is a loop, and a loop that
leaves production down is worse than reaping a process we started ourselves and
can name.

**`AbandonProcessGroup`.** The plist does not set it, so it defaults to false and
launchd already kills the process group when it *stops* the job. That is why a
deliberate `brew services stop` leaves nothing behind, and it is worth writing
down: the leak is a crash-restart property, not a deploy property, and the plist
needs no change.

### 3. The supervisor's own log stops being buffered

`$stdout.sync = true` for the console stream, so a lifecycle line is on disk
before the next statement runs. One line of code, and it is what turns the next
occurrence into evidence instead of an absence.

That also separates the two readings above for free: with a synced log, a boot
that dies between the two spawns looks different from one that dies later, and
the first task of the implementation is to run with it and see which it is
before touching anything else. If it turns out to be the second, §1 already
covers it — the fix does not depend on the answer, only on knowing it.

### 4. The queue supervisor and its forks

The ticket asks whether the worker and scheduler leak the same way. They can, by
the same `ensure` gap, whenever the death happens after both spawns: the queue
supervisor is a direct child, so it is TERMed like puma and passes the signal to
its three forks — but only if `shutdown_children` runs at all. The same fix
covers it, and the tests assert it on both children rather than on puma alone.

The 01/09 observation found only a puma because the death was before the second
spawn, not because the queue side is immune.

### 5. Where the code goes

* `lib/autodev/supervisor.rb` — the `ensure`, and the boot guard's call site.
* `lib/autodev/logger.rb` — `$stdout.sync`.
* `bin/autodev` — where the guard runs, before `run_supervisor`.

## Testing

The supervisor already has injection seams (`spawner:`, `sleeper:`), which is
what makes this testable without spawning anything real.

* `spawn_all` raises on the second child → the first child is TERMed. The
  regression, and it is written first.
* `wait_loop` raises → every child is TERMed.
* The normal path is unchanged: one shutdown, not two, and no double TERM.
* `shutdown_children` run twice in a row is harmless.
* A child that ignores TERM is still KILLed after the grace — the existing
  behaviour, pinned so the `ensure` cannot weaken it.
* The boot guard: a recognised orphan of ours is reaped and logged; an
  unrecognised process holding the database makes the boot refuse with a message
  naming it; nothing holding it is a silent pass.
* Both children are covered by every case above, not just `rails-server`.

## Docs

* `CLAUDE.md`'s "Process topology" describes the shutdown as TERM → grace →
  KILL; it needs the `ensure` and the boot guard, and it should say that the
  children share the supervisor's process group (the opposite of what this
  ticket assumed, so worth writing down).
* `CHANGELOG.md` `[Unreleased]`.
* i18n fr **and** en for the boot-guard messages — they are `cli_*` strings, per
  `bin/autodev`'s existing boot diagnostics.

## Constraints

TDD. RuboCop green over the whole tree. Conventional Commits. `CHANGELOG.md`
`[Unreleased]` updated in the same pass. i18n fr **and** en for every visible
string. Branch `fix/92-a-dying-supervisor-takes-its-children`.

## Out of scope

* **Why the supervisor dies in the first place.** This ticket stops the leak and
  makes the next occurrence legible; naming the first cause needs the synced log
  and a fresh observation. Deliberately not guessed at here — the ticket's own
  guess was wrong, and 125 `LoadError` and 44
  `ActionDispatch::RemoteIp::IpSpoofAttackError` in the stderr are candidates
  nothing yet connects to a supervisor death.
* **A health card for a stale process.** `HealthReport` is passive and reads
  rows, and it cannot see a process. Worth its own ticket if the leak survives
  this one.
* **`ProcessRunner`'s `pgroup: true`.** Untouched, and the ticket's caveat about
  not breaking what it buys does not apply — the supervisor never used it.
