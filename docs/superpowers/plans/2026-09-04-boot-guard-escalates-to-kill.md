# Boot guard escalates to KILL — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The boot guard stops an orphaned process for real — TERM, bounded wait, KILL, verification — and every sentence it logs states an outcome it has observed.

**Architecture:** A new `Autodev::ProcessStopper` module carries the escalation on a *bare pid* (no `Process.wait`, because the orphan belongs to init, not to us). `BootGuard` calls it through a `stopper:` seam and logs one of three distinct outcomes. An orphan surviving SIGKILL warns and lets the boot proceed; `AUTODEV_BOOT_GUARD_STRICT=1` turns that one case into a refusal.

**Tech Stack:** Ruby 3.x, Minitest, RuboCop, I18n (`Autodev::Locales`), no new gems.

**Spec:** `docs/superpowers/specs/2026-09-04-boot-guard-escalates-to-kill-design.md`

## Global Constraints

- **TDD.** Every test must be verified red before its implementation, and red again with the implementation removed. The alpha-53 neutral review found four fixes in this repository with no test capable of failing, one of them in this very file.
- **RuboCop green on the whole tree**: `mise x ruby -- rubocop`. Never edit any `.rubocop.yml`.
- **`CHANGELOG.md` `[Unreleased]`** updated in the same pass as the code (Task 6).
- **Conventional Commits**: `<type>: <description>` plus a body. Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`.
- **i18n `fr` AND `en`** for every visible string, with identical placeholders in both files.
- **Every test file must pass run on its own**: `bundle exec ruby -Itest test/boot_guard_test.rb` (Autodev #64), not only under `bundle exec rake test`.
- Comments and code in English; this plan and the spec are in English.
- **Do not touch** `app/services/autodev/poll_dispatcher.rb`, `app/jobs/issue_process_job.rb`, `lib/autodev/pipeline_monitor/infra_recheck.rb` or `app/services/autodev/review_arrears_sweep.rb` — they belong to the other two branches of the alpha 54 lot.

---

## File Structure

- **Create** `lib/autodev/process_stopper.rb` — the escalation, on a bare pid. One responsibility: turn "stop this pid" into one of three observed verdicts.
- **Create** `test/process_stopper_test.rb` — unit tests with injected seams, plus one real-subprocess test.
- **Modify** `lib/autodev/boot_guard.rb` — `reap` calls the stopper and logs the verdict; `@killer` becomes `@stopper`.
- **Modify** `test/boot_guard_test.rb` — `build_guard`'s seam, and the new outcome/strict tests.
- **Modify** `config/locales/cli.fr.yml`, `config/locales/cli.en.yml` — one key rewritten, three added.
- **Modify** `lib/autodev.rb` — require the new file if the require graph is explicit there.
- **Modify** `CLAUDE.md`, `CHANGELOG.md` — Task 6.
- **Possibly modify** `lib/autodev/supervisor.rb` — Task 5, under a mechanical acceptance criterion that may well say "do not".

---

### Task 1: `Autodev::ProcessStopper` — the escalation on a bare pid

**Files:**
- Create: `lib/autodev/process_stopper.rb`
- Create: `test/process_stopper_test.rb`
- Modify: `lib/autodev.rb` (add the require if that file lists them explicitly — check first with `grep -n "boot_guard" lib/autodev.rb`; if `boot_guard` is required there, require `process_stopper` the same way, alphabetically)

**Interfaces:**
- Consumes: nothing.
- Produces: `Autodev::ProcessStopper.stop(pid, grace: DEFAULT_GRACE_SECONDS, overrides: {}) -> Symbol`, returning `:gone_on_term`, `:gone_on_kill` or `:alive`. `overrides` accepts `:alive` (`(pid) -> bool`), `:killer` (`(sig_name, pid) -> bool`, false meaning "already gone"), `:sleeper` (`(seconds) -> void`), `:clock` (`() -> Float`). Also `Autodev::ProcessStopper::DEFAULT_GRACE_SECONDS = 10` and `KILL_CONFIRM_SECONDS = 2`.

The `overrides:` hash rather than four keyword arguments is not a style choice: `BootGuard#initialize` already uses exactly this idiom for its own seams, and RuboCop's `Metrics/ParameterLists` counts keyword arguments.

- [ ] **Step 1: Write the failing tests**

Create `test/process_stopper_test.rb`:

```ruby
# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/process_stopper'

# Autodev #109: `BootGuard#reap` sent one TERM, logged "Arrêt en cours (TERM)"
# and moved on. The alpha-52 puma survived that TERM for forty minutes, holding
# the production database, its WAL and its shared-memory file open for writing.
#
# This module is the escalation the guard did not have, on a **bare pid**:
# `Supervisor#force_kill_stragglers` ends in `Process.wait`, which raises
# `ECHILD` on an orphan that belongs to init. Liveness is `Process.kill(0, pid)`
# and nothing here ever reaps.
class ProcessStopperTest < Minitest::Test
  def setup
    @signals = []
    @now = 0.0
  end

  # A clock that only moves when the sleeper is called, so a test drives the
  # deadline explicitly instead of waiting on the wall clock.
  def seams(alive:)
    { alive: alive,
      killer: ->(sig, pid) { @signals << [sig, pid]; true },
      sleeper: ->(seconds) { @now += seconds },
      clock: -> { @now } }
  end

  def test_a_process_that_honours_term_is_gone_without_a_kill
    calls = 0
    alive = lambda do |_pid|
      calls += 1
      calls <= 1 # alive on the first look, gone on the second
    end

    verdict = Autodev::ProcessStopper.stop(555, grace: 10, overrides: seams(alive: alive))

    assert_equal :gone_on_term, verdict
    assert_equal [['TERM', 555]], @signals, 'a process that honours TERM must never be KILLed'
  end

  def test_a_process_that_ignores_term_is_killed_after_the_grace
    kills = 0
    alive = lambda do |_pid|
      # Alive until KILL is sent, gone on the first look after it.
      !@signals.include?(['KILL', 555]) || (kills += 1) < 1
    end

    verdict = Autodev::ProcessStopper.stop(555, grace: 1, overrides: seams(alive: alive))

    assert_equal :gone_on_kill, verdict
    assert_equal [['TERM', 555], ['KILL', 555]], @signals
  end

  def test_a_process_that_survives_kill_is_reported_alive
    verdict = Autodev::ProcessStopper.stop(555, grace: 1, overrides: seams(alive: ->(_pid) { true }))

    assert_equal :alive, verdict
    assert_equal [['TERM', 555], ['KILL', 555]], @signals,
                 'both signals must have been attempted before giving up'
  end

  def test_a_pid_already_gone_when_term_is_sent_is_gone_on_term
    overrides = seams(alive: ->(_pid) { true })
    overrides[:killer] = ->(sig, pid) { @signals << [sig, pid]; false } # ESRCH

    verdict = Autodev::ProcessStopper.stop(555, grace: 1, overrides: overrides)

    assert_equal :gone_on_term, verdict
    assert_equal [['TERM', 555]], @signals, 'a pid that was already gone needs no KILL'
  end

  def test_the_default_grace_matches_the_supervisors
    require 'autodev/supervisor'

    assert_equal Autodev::Supervisor::TERM_GRACE_SECONDS,
                 Autodev::ProcessStopper::DEFAULT_GRACE_SECONDS,
                 'the two escalations must not drift apart by accident'
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec ruby -Itest test/process_stopper_test.rb`
Expected: FAIL — `cannot load such file -- autodev/process_stopper`.

- [ ] **Step 3: Write the implementation**

Create `lib/autodev/process_stopper.rb`:

```ruby
# frozen_string_literal: true

module Autodev
  # Autodev #109. Stop a process and *observe* that it stopped.
  #
  # `BootGuard#reap` used to send one TERM and log "Stopping it (TERM)". At the
  # alpha-53 deployment (03/09/2026 17h18) the alpha-52 puma survived that TERM
  # and stayed alive for forty minutes, holding `autodev.db`, its WAL and its
  # shared-memory file open for writing on three descriptors. A manual KILL was
  # needed; `PRAGMA wal_checkpoint(PASSIVE)` answered `0|322|322` immediately
  # afterwards, which is the checkpoint the ghost had been blocking.
  #
  # == Why this is not `Supervisor#shutdown_children`
  #
  # The supervisor has the same shape — TERM, bounded wait, KILL — but it works
  # on **its own children**: `force_kill_stragglers` ends in `Process.wait`,
  # which raises `ECHILD` on a foreign pid. A boot guard's orphan belongs to
  # pid 1; init reaps it, and trying to reap it here would be an error. So the
  # shape is shared and the code is not. There is deliberately no `Process.wait`
  # anywhere in this file.
  #
  # Liveness is `Process.kill(0, pid)`, the same question `Supervisor::Child#alive?`
  # asks: `ESRCH` is gone, `EPERM` is alive and somebody else's.
  module ProcessStopper
    # The same value as `Supervisor::TERM_GRACE_SECONDS`, declared here rather
    # than read from there: a module operating on a bare pid must not depend on
    # the supervisor, and that dependency would have to be undone if the
    # supervisor ever adopts this module. `test/process_stopper_test.rb` asserts
    # the two stay equal.
    DEFAULT_GRACE_SECONDS = 10

    # SIGKILL cannot be caught, so this is a confirmation window and not a
    # grace: it covers the microseconds between the signal and the process
    # leaving the table, not any work the process might do.
    KILL_CONFIRM_SECONDS = 2

    POLL_INTERVAL_SECONDS = 0.2

    module_function

    # Returns one of :gone_on_term, :gone_on_kill, :alive — always a statement
    # about what was observed, never about what was requested.
    def stop(pid, grace: DEFAULT_GRACE_SECONDS, overrides: {})
      alive = overrides[:alive] || method(:alive?)
      killer = overrides[:killer] || method(:signal)
      sleeper = overrides[:sleeper] || method(:sleep)
      clock = overrides[:clock] || method(:monotonic_now)

      return :gone_on_term unless killer.call('TERM', pid)
      return :gone_on_term if gone_within?(pid, grace, alive, sleeper, clock)
      return :gone_on_kill unless killer.call('KILL', pid)
      return :gone_on_kill if gone_within?(pid, KILL_CONFIRM_SECONDS, alive, sleeper, clock)

      :alive
    end

    def gone_within?(pid, seconds, alive, sleeper, clock)
      deadline = clock.call + seconds
      loop do
        return true unless alive.call(pid)
        return false if clock.call >= deadline

        sleeper.call(POLL_INTERVAL_SECONDS)
      end
    end

    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    # `false` means "already gone", which is the outcome we wanted rather than
    # an error: a process that died between two instructions is stopped.
    def signal(sig, pid)
      Process.kill(sig, pid)
      true
    rescue Errno::ESRCH
      false
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec ruby -Itest test/process_stopper_test.rb`
Expected: PASS, 5 runs, 0 failures.

- [ ] **Step 5: Verify the tests are capable of failing**

Temporarily change `return :gone_on_kill unless killer.call('KILL', pid)` and the line below it to `return :alive`, re-run, and confirm `test_a_process_that_ignores_term_is_killed_after_the_grace` fails. Restore.

Run: `mise x ruby -- rubocop lib/autodev/process_stopper.rb test/process_stopper_test.rb`
Expected: no offenses.

- [ ] **Step 6: Commit**

```bash
git add lib/autodev/process_stopper.rb test/process_stopper_test.rb lib/autodev.rb
git commit -m "feat: ProcessStopper escalates TERM to KILL and reports what it observed

Autodev #109. The escalation on a bare pid, which Supervisor's version cannot
be because force_kill_stragglers ends in Process.wait — ECHILD on an orphan that
belongs to init. Three verdicts, so a caller can state an outcome instead of
announcing an intention."
```

---

### Task 2: The real-subprocess test — a child that ignores SIGTERM

**Files:**
- Modify: `test/process_stopper_test.rb`

**Interfaces:**
- Consumes: `Autodev::ProcessStopper.stop` from Task 1.
- Produces: nothing.

This is the test whose absence let the defect through, and no stub can stand in for it: the defect was that a *real* process did not do what the code assumed. Note that `test_child_ignoring_term_is_still_killed_after_the_grace` in `test/supervisor_test.rb:181` is **not** a real-subprocess test despite what Autodev #109's text says — it stubs `Process.kill` and `Process.clock_gettime`. The real harness to copy is `spawn_holder` in `test/boot_guard_test.rb:299`.

- [ ] **Step 1: Write the failing test**

Append to `test/process_stopper_test.rb`, inside the class:

```ruby
  # --- against a real process, which is the only thing that could have caught
  # --- the defect this ticket is about --------------------------------------

  def test_a_real_subprocess_ignoring_sigterm_is_killed
    with_stubborn_child do |pid|
      verdict = Autodev::ProcessStopper.stop(pid, grace: 1)

      assert_equal :gone_on_kill, verdict
      Process.wait(pid) # this one IS our child, so we reap it here
      assert_raises(Errno::ESRCH, 'the process must really be gone') { Process.kill(0, pid) }
    end
  end

  def test_a_real_subprocess_honouring_sigterm_is_gone_without_a_kill
    with_stubborn_child(ignore_term: false) do |pid|
      verdict = Autodev::ProcessStopper.stop(pid, grace: 5)

      assert_equal :gone_on_term, verdict
      Process.wait(pid)
    end
  end

  private

  # Modelled on `spawn_holder` / `with_held_database` in test/boot_guard_test.rb:
  # a real Ruby child, a readiness file so the test never races the trap being
  # installed, and an `ensure` that KILLs whatever survived the assertions.
  def with_stubborn_child(ignore_term: true)
    Dir.mktmpdir('process-stopper') do |dir|
      ready = File.join(dir, 'ready')
      pid = spawn(RbConfig.ruby, '-e', child_script(ready, ignore_term: ignore_term),
                  out: File::NULL, err: File::NULL)
      wait_for_readiness(ready)
      begin
        yield pid
      ensure
        force_reap(pid)
      end
    end
  end

  def child_script(ready_path, ignore_term:)
    <<~RUBY
      Signal.trap('TERM') { } if #{ignore_term}
      File.write(#{ready_path.inspect}, 'ok')
      sleep 60
    RUBY
  end

  def wait_for_readiness(path, timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.05 until File.exist?(path) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    raise "child never became ready (#{path})" unless File.exist?(path)
  end

  def force_reap(pid)
    Process.kill('KILL', pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil # already gone, which is the normal path after a successful stop
  end
```

Add `require 'tmpdir'` and `require 'rbconfig'` at the top of the file if `test_helper` does not already provide them (`test_helper.rb` requires `tmpdir`; check before adding).

- [ ] **Step 2: Run to verify the stubborn case fails without the escalation**

Run: `bundle exec ruby -Itest test/process_stopper_test.rb -n test_a_real_subprocess_ignoring_sigterm_is_killed`
Expected: PASS with Task 1 in place. To prove the test has teeth, temporarily make `stop` return `:alive` right after the TERM branch and confirm it fails. Restore.

- [ ] **Step 3: Run the whole file**

Run: `bundle exec ruby -Itest test/process_stopper_test.rb`
Expected: PASS, 7 runs, 0 failures. The two real-subprocess tests should take under two seconds combined; if either hangs, the readiness file or the `ensure` is wrong.

- [ ] **Step 4: RuboCop**

Run: `mise x ruby -- rubocop test/process_stopper_test.rb`
Expected: no offenses. If `Metrics/MethodLength` fires on `with_stubborn_child`, add a targeted `# rubocop:disable Metrics/MethodLength` with the reason on the line above, as `test/boot_guard_test.rb` does for its own harness — never edit `.rubocop.yml`.

- [ ] **Step 5: Commit**

```bash
git add test/process_stopper_test.rb
git commit -m "test: exercise the escalation against a real process that ignores SIGTERM

Autodev #109. The six existing boot-guard tests all injected a killer that
recorded a pid and killed nothing, so no test ever had a process to observe —
which is exactly the defect. Modelled on spawn_holder in boot_guard_test, not on
supervisor_test's stubbed version."
```

---

### Task 3: `BootGuard` calls the stopper and logs three distinct outcomes

**Files:**
- Modify: `lib/autodev/boot_guard.rb` (the `@killer` seam, `reap`, `default_kill`)
- Modify: `config/locales/cli.fr.yml`, `config/locales/cli.en.yml`
- Modify: `test/boot_guard_test.rb` (`setup`, `build_guard`)

**Interfaces:**
- Consumes: `Autodev::ProcessStopper.stop(pid, grace:, overrides:)` from Task 1.
- Produces: `BootGuard`'s `overrides[:stopper]` seam — a callable `(pid) -> Symbol` replacing `overrides[:killer]`.

The four locale keys, `fr` and `en`, with identical placeholders:

| key | placeholders |
|---|---|
| `cli_boot_guard_orphan_found` (rewrite of `cli_boot_guard_reaped_orphan`) | `name`, `pid`, `pgid`, `db_path` |
| `cli_boot_guard_orphan_stopped_term` | `name`, `pid` |
| `cli_boot_guard_orphan_stopped_kill` | `name`, `pid`, `grace` |
| `cli_boot_guard_orphan_survived` | `name`, `pid`, `command`, `db_path` |

The discovery sentence must lose its trailing "Stopping it (TERM)." / "Arrêt en cours (TERM)." — that clause is the false claim this whole ticket is about.

- [ ] **Step 1: Write the failing tests**

In `test/boot_guard_test.rb`, replace the `@killer` seam in `setup` and `build_guard`:

```ruby
  def setup
    @logger = FakeLogger.new
    @killed = []
    @verdict = :gone_on_term
    @stopper = ->(pid) { @killed << pid; @verdict }
  end
```

and in `build_guard`, change `killer: @killer` to `stopper: @stopper`. Every existing test goes through this helper, so this is the only edit they need.

Then add, in the "what gets reaped" section:

```ruby
  def test_an_orphan_that_honours_term_is_reported_stopped_without_a_kill
    @verdict = :gone_on_term
    guard = build_guard(holders: [build_holder(pid: 555, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')])

    guard.call

    assert_equal [555], @killed
    assert(messages.any? { |m| m.include?('555') && m.match?(/SIGTERM|TERM/) },
           'the outcome must be stated, and it must name the pid')
  end

  def test_an_orphan_that_ignores_term_reports_the_kill
    @verdict = :gone_on_kill
    guard = build_guard(holders: [build_holder(pid: 555, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')])

    guard.call

    kill_lines = @logger.entries.select { |level, msg| level == :warn && msg.include?('555') }

    refute_empty kill_lines, 'a straggler killed after the grace must be visible at warn level'
  end

  # The 03/09 case: the boot must NOT stop, and the pid must be named.
  def test_an_orphan_that_survives_kill_warns_and_lets_the_boot_proceed
    @verdict = :alive
    guard = build_guard(holders: [build_holder(pid: 1383, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')])

    guard.call # must not raise

    assert(messages.any? { |m| m.include?('1383') },
           'a surviving orphan must be named so an operator can find it')
  end

  def test_the_discovery_sentence_no_longer_announces_a_stop
    @verdict = :alive
    guard = build_guard(holders: [build_holder(pid: 1383, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')])

    guard.call

    refute(messages.any? { |m| m.include?('Stopping it (TERM)') },
           'the discovery sentence must not claim an outcome it has not observed')
  end
```

Add the helper beside `build_holder`:

```ruby
  def messages = @logger.entries.map(&:last)
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec ruby -Itest test/boot_guard_test.rb`
Expected: FAIL — the guard still calls a one-argument `killer` and still logs the old sentence.

- [ ] **Step 3: Write the implementation**

In `lib/autodev/boot_guard.rb`, add `require 'autodev/process_stopper'` beside `require 'open3'`, then in `initialize` replace the `@killer` line with:

```ruby
      @stopper = overrides[:stopper] || ->(pid) { ProcessStopper.stop(pid) }
```

Replace `reap` and delete `default_kill`:

```ruby
    # Discovery and outcome are two sentences on purpose. A single one would
    # have to be written before the result is known, which is how this defect
    # was born (Autodev #109): the old key ended with "Stopping it (TERM)" and
    # nothing ever checked.
    def reap(holder, name)
      @logger.warn(Locales.t(:cli_boot_guard_orphan_found, locale: @locale,
                                                           name: name, pid: holder.pid,
                                                           pgid: holder.pgid, db_path: @db_path))
      announce(@stopper.call(holder.pid), holder, name)
    end

    def announce(verdict, holder, name)
      case verdict
      when :gone_on_term
        @logger.info(Locales.t(:cli_boot_guard_orphan_stopped_term, locale: @locale,
                                                                    name: name, pid: holder.pid))
      when :gone_on_kill
        @logger.warn(Locales.t(:cli_boot_guard_orphan_stopped_kill, locale: @locale,
                                                                    name: name, pid: holder.pid,
                                                                    grace: ProcessStopper::DEFAULT_GRACE_SECONDS))
      else
        survived(holder, name)
      end
    end

    # An orphan that survives SIGKILL is remarkable, and it still does not
    # justify refusing the boot: a false refusal is a total outage repeated on
    # every launchd restart under `KeepAlive: Crashed`, a false pass is one
    # ghost process. Strict mode is where an operator investigating by hand
    # gets the refusal.
    def survived(holder, name)
      msg = Locales.t(:cli_boot_guard_orphan_survived, locale: @locale,
                                                       name: name, pid: holder.pid,
                                                       command: holder.command, db_path: @db_path)
      raise ConfigError, msg if @strict

      @logger.warn(msg)
    end
```

Add to `config/locales/cli.en.yml` (replacing the `cli_boot_guard_reaped_orphan` line):

```yaml
  cli_boot_guard_orphan_found: "Found an orphaned process at boot: %{name} (pid=%{pid}), a child of a previous supervisor whose process group %{pgid} has lost its leader, holding %{db_path} open."
  cli_boot_guard_orphan_stopped_term: "Orphaned process %{name} (pid=%{pid}) stopped on SIGTERM."
  cli_boot_guard_orphan_stopped_kill: "Orphaned process %{name} (pid=%{pid}) ignored SIGTERM and was killed after %{grace}s."
  cli_boot_guard_orphan_survived: "Orphaned process %{name} (pid=%{pid}, command: %{command}) survived SIGKILL and is still holding %{db_path}. Autodev is starting anyway — stop that process by hand, and set AUTODEV_BOOT_GUARD_STRICT=1 if you want the boot to refuse instead."
```

And to `config/locales/cli.fr.yml`:

```yaml
  cli_boot_guard_orphan_found: "Processus orphelin détecté au démarrage : %{name} (pid=%{pid}), enfant d'un superviseur précédent dont le groupe de processus %{pgid} n'a plus de chef, gardant %{db_path} ouvert."
  cli_boot_guard_orphan_stopped_term: "Processus orphelin %{name} (pid=%{pid}) arrêté sur SIGTERM."
  cli_boot_guard_orphan_stopped_kill: "Processus orphelin %{name} (pid=%{pid}) a ignoré SIGTERM et a été tué après %{grace}s."
  cli_boot_guard_orphan_survived: "Le processus orphelin %{name} (pid=%{pid}, commande : %{command}) a survécu à SIGKILL et retient toujours %{db_path}. Autodev démarre quand même — arrêtez ce processus manuellement, et posez AUTODEV_BOOT_GUARD_STRICT=1 si vous préférez que le démarrage soit refusé."
```

- [ ] **Step 4: Run the tests**

Run: `bundle exec ruby -Itest test/boot_guard_test.rb`
Expected: PASS. The nine pre-existing tests must pass unchanged apart from the `build_guard` seam rename — if any of them needs a change to its body, stop and re-read: it means the classification behaviour moved, which this task must not do.

- [ ] **Step 5: Check the i18n key scan**

Run: `bundle exec rake test TEST=test/i18n_keys_test.rb` (find the actual file with `ls test | grep -i i18n`; Autodev #68/#73 added a scan that reads keys off their call sites).
Expected: PASS, all four keys present in `fr` and `en` with identical placeholders.

- [ ] **Step 6: Commit**

```bash
git add lib/autodev/boot_guard.rb test/boot_guard_test.rb config/locales/cli.fr.yml config/locales/cli.en.yml
git commit -m "fix: the boot guard states the outcome it observed, and escalates to KILL

Autodev #109. reap sent one TERM, logged 'Stopping it (TERM)' and moved on; the
alpha-52 puma survived it for forty minutes with the database, its WAL and its
shared memory open for writing. Discovery and outcome are now two sentences, so
neither has to be written before the result is known, and the three outcomes are
distinct. A survivor of SIGKILL warns and the boot proceeds — a false refusal is
a total outage in a KeepAlive: Crashed loop."
```

---

### Task 4: Strict mode refuses only on a surviving orphan

**Files:**
- Modify: `test/boot_guard_test.rb`

**Interfaces:**
- Consumes: `survived` from Task 3.
- Produces: nothing.

Task 3 already wired `raise ConfigError if @strict` into `survived`. This task proves the boundary, because getting it wrong in the other direction — refusing after a *successful* reap — would leave an operator unable to boot at all.

- [ ] **Step 1: Write the failing tests**

```ruby
  def test_strict_mode_refuses_when_an_orphan_survives_kill
    @verdict = :alive
    guard = build_guard(holders: [build_holder(pid: 1383, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')],
                        strict: true)

    error = assert_raises(ConfigError) { guard.call }

    assert_includes error.message, '1383'
  end

  def test_strict_mode_does_not_refuse_after_a_successful_reap
    @verdict = :gone_on_kill
    guard = build_guard(holders: [build_holder(pid: 555, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')],
                        strict: true)

    guard.call # must not raise: an operator investigating by hand must still be able to boot

    assert_equal [555], @killed
  end
```

- [ ] **Step 2: Run to verify they fail, then pass**

Run: `bundle exec ruby -Itest test/boot_guard_test.rb -n "/strict_mode/"`
Expected: with Task 3 in place both pass. Prove they have teeth: temporarily move the `raise` out of `survived` into `announce` unconditionally and confirm `test_strict_mode_does_not_refuse_after_a_successful_reap` fails. Restore.

- [ ] **Step 3: Commit**

```bash
git add test/boot_guard_test.rb
git commit -m "test: strict mode refuses a surviving orphan and only that

Autodev #109. Refusing after a successful reap would leave an operator
investigating by hand unable to boot at all, which is the failure mode the
alpha-53 review called blocking."
```

---

### Task 5: Decide whether `Supervisor` adopts `ProcessStopper`

**Files:**
- Modify: `lib/autodev/supervisor.rb` — **only if the criterion below is met**

**Interfaces:**
- Consumes: `Autodev::ProcessStopper` from Task 1.
- Produces: nothing new either way.

Autodev #109 asks whether the escalation is shareable rather than rewritten. The answer is now half known: the *shape* is, the code is not, because `force_kill_stragglers` must `Process.wait` its own children and `ProcessStopper` must never `Process.wait` anything.

**The acceptance criterion is mechanical: adopt only if `test/supervisor_test.rb` needs no edit at all.** A partial migration leaving two escalations that differ by accident is worse than two that differ on purpose.

- [ ] **Step 1: Attempt the adoption on a scratch commit**

Try replacing `Supervisor#wait_for_graceful_exit` + `force_kill_stragglers` with a per-child `ProcessStopper.stop`, keeping `Process.wait` in the supervisor for reaping.

Run: `bundle exec ruby -Itest test/supervisor_test.rb`

- [ ] **Step 2: Judge**

- If the suite passes with **zero** edits to `test/supervisor_test.rb`, keep the change and go to Step 3.
- Otherwise `git checkout -- lib/autodev/supervisor.rb` and go to Step 4. This is a legitimate outcome, not a failure: `send_term` logs per child and the supervisor's reaping obligations are real.

- [ ] **Step 3 (adoption path): Commit**

```bash
git add lib/autodev/supervisor.rb
git commit -m "refactor: Supervisor stops its children through ProcessStopper

Autodev #109. One escalation, two callers. The supervisor keeps Process.wait for
its own children; ProcessStopper never reaps, because a boot guard's orphan
belongs to init."
```

- [ ] **Step 4 (declined path): Write the reason down and commit**

Add above `Supervisor#shutdown_children`:

```ruby
    # `Autodev::ProcessStopper` (Autodev #109) has the same shape for a *foreign*
    # pid. This one is not written in terms of it: `send_term` logs per child,
    # and `force_kill_stragglers` must `Process.wait` — these are our children
    # and we owe them a reap, where the boot guard's orphans belong to init.
    # Two escalations on purpose, not by accident; the grace is asserted equal
    # in test/process_stopper_test.rb.
```

```bash
git add lib/autodev/supervisor.rb
git commit -m "docs: name ProcessStopper beside the supervisor's own escalation

Autodev #109. Instructed and declined: the two cannot share code because one
owes its children a reap and the other must never reap. Written where the next
reader will look for it."
```

---

### Task 6: Why that puma ignored its TERM, plus docs and changelog

**Files:**
- Modify: `CLAUDE.md` (topology section, the boot guard paragraphs)
- Modify: `CHANGELOG.md` (`[Unreleased]`)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Test the hypothesis, cheaply**

Point 4 of the ticket. The hypothesis is a graceful shutdown waiting for something that will never arrive — the ghost had no listener (the new puma had taken the port) and its supervisor was dead. Reproduce locally:

```bash
bundle exec ruby -e 'pid = spawn("bin/rails", "server", "-p", "4599"); sleep 5; Process.kill("TERM", pid); sleep 3; puts (Process.kill(0, pid) rescue "gone")'
```

Then repeat with the port already taken by a second server, so the child never binds. Record what you observe in one paragraph — **and if it does not reproduce, write that instead.** An unreproduced hypothesis stated as a cause is precisely the fault this ticket exists to correct. This step gates nothing: Task 3 is correct either way.

- [ ] **Step 2: Update `CLAUDE.md`**

Find the boot guard paragraphs (`grep -n "BootGuard\|boot guard" CLAUDE.md`). Replace the sentence describing the TERM with the escalation, and add the surviving-orphan case to the "unidentified holder" paragraph. Keep it to the same register as the surrounding text.

- [ ] **Step 3: Update `CHANGELOG.md`**

Add under `## [Unreleased]` a `### Fixed` entry. It must carry the 03/09 measurement, because that is what makes the harm concrete: pid 1383, alive since 15h53, RSS 151 MB (the ticket estimated 60), three descriptors on `autodev.db`, its WAL and its shared-memory file, and `PRAGMA wal_checkpoint(PASSIVE)` answering `0|322|322` immediately after the manual KILL. State the outcome of Step 1 in one sentence, whichever way it went.

- [ ] **Step 4: Full suite and RuboCop**

Run: `bundle exec rake test`
Expected: 0 failures, 0 errors.

Run: `bundle exec ruby -Itest test/boot_guard_test.rb && bundle exec ruby -Itest test/process_stopper_test.rb`
Expected: both pass **standalone** (Autodev #64).

Run: `mise x ruby -- rubocop`
Expected: no offenses, whole tree.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md CHANGELOG.md
git commit -m "docs: record the boot guard escalation and the 03/09 measurement

Autodev #109."
```

---

## Definition of done

- `bundle exec rake test` green; `test/boot_guard_test.rb` and `test/process_stopper_test.rb` each green standalone.
- `mise x ruby -- rubocop` clean on the whole tree.
- Four locale keys present in `fr` and `en` with identical placeholders; no key still claims an outcome.
- No test asserts an outcome the code merely requested.
- `CHANGELOG.md` `[Unreleased]` carries the fix and the measurement.
- Task 5 committed one way or the other, with its reason written in the code.
