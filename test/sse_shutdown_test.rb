# frozen_string_literal: true

require_relative 'test_helper'
require 'socket'
require 'tmpdir'
require 'securerandom'
require 'rbconfig'

# Autodev #112: an open SSE connection (`GET /stream`, served through
# `ActionController::Live`) never releases its Puma thread on its own — the
# alpha-16 changelog entry says so itself, "stays open for the lifetime of
# the tab" — and Puma's own `graceful_shutdown` has no timeout without
# `force_shutdown_after` (puma 6.6.1, `lib/puma/server.rb:604-609`:
# `@thread_pool.shutdown` is called with no deadline when the option is
# nil). One open browser tab therefore blocked shutdown indefinitely:
# `graceful_shutdown` closes the listening socket *before* waiting on the
# thread pool, so the old process releases the port at once (letting a new
# one bind it) but keeps running, holding `~/.autodev/autodev.db`, its WAL
# and its shared-memory file open for writing — measured on production
# holding them for 40 minutes on 03/09/2026.
#
# This is the real-server proof the ticket asks for: it boots the app's own
# `puma -C config/puma.rb`, in a genuinely separate OS process, attaches a
# real socket to `/stream` and leaves it open (unlike every other client in
# this suite, this one never disconnects), sends that process a real
# SIGTERM, and asserts it is gone within a bounded time despite the still-
# open stream.
#
# Authentication: `/stream` sits behind Devise's `authenticate_user!`, and
# staging a real Entra ID + GitLab-sync sign-in from outside the process is
# what `test/controllers/users/omniauth_callbacks_controller_test.rb`
# already declined for this exact controller action ("fragile ... under
# Devise + omniauth-rails_csrf_protection", and it would also need a live
# GitLab here). `config/environments/test.rb` carries the substitute: a
# `Warden.test_mode!` login, gated behind `AUTODEV_WARDEN_TEST_LOGIN_EMAIL`,
# which only this test ever sets.
#
# Modelled on test/process_stopper_test.rb's `with_stubborn_child`: a real
# subprocess harness (temp dir, port, HTTP client, teardown) is the point —
# a stub here would prove nothing about a defect that lives entirely in
# Puma's own process lifecycle.
#
# rubocop:disable Metrics/ClassLength -- three real-subprocess cases (the
# positive proof; the negative check that the test-only login shortcut
# cannot authenticate a request on its own; and the teeth proof that
# `assert_puma_process` would actually catch a wrapper pid) share one
# harness; splitting it out would not shrink the total, only hide it behind
# a require.
class SseShutdownTest < Minitest::Test
  APP_ROOT = File.expand_path('..', __dir__)
  # `force_shutdown_after` is 2s (config/puma.rb), but that is not the whole
  # wait — Puma's own fixed `SHUTDOWN_GRACE_TIME` (5s, `lib/puma/
  # thread_pool.rb`, not reachable from the public DSL) runs after it before
  # the stuck thread is actually killed. Measured against a real client
  # attached to `/stream` (AGENT-REPORT.md): ~7.1s wall time to exit. This
  # bound adds slack for process spawn/teardown and CI scheduling jitter on
  # top of that measurement — it is not itself a measurement of the fix,
  # just how long we're willing to wait for one, and it stays comfortably
  # under `Autodev::Supervisor::TERM_GRACE_SECONDS` (10s).
  EXIT_BOUND_SECONDS = 9
  BOOT_TIMEOUT_SECONDS = 20
  # See `assert_puma_process`'s own comment for why this is anchored.
  PUMA_COMMAND_PATTERN = /\Apuma\b/
  STREAM_REQUEST = "GET /stream HTTP/1.1\r\nHost: 127.0.0.1\r\n" \
                   "Accept: text/event-stream\r\nConnection: keep-alive\r\n\r\n"
  # Same request, `Connection: close` — for the one-shot negative case,
  # where the server closing once it's done lets `socket.read` see the
  # whole response instead of a request that would otherwise hang open.
  PROBE_REQUEST = "GET /stream HTTP/1.1\r\nHost: 127.0.0.1\r\n" \
                  "Accept: text/event-stream\r\nConnection: close\r\n\r\n"

  def test_a_real_server_with_an_open_stream_connection_still_exits_within_bound_of_sigterm
    with_real_server do |pid, port|
      socket = open_stream_connection(port)

      assert_puma_process(pid)

      Process.kill('TERM', pid)
      status = wait_for_exit(pid, EXIT_BOUND_SECONDS)
      socket.close

      refute_nil status,
                 "puma (pid=#{pid}) was still alive #{EXIT_BOUND_SECONDS}s after SIGTERM " \
                 'with an open /stream client attached — force_shutdown_after did not cut it'
    end
  end

  # The proof above only means what it claims to mean if the login shortcut
  # (config/environments/test.rb, gated behind AUTODEV_WARDEN_TEST_LOGIN_EMAIL)
  # cannot authenticate a request on its own — an auth bypass nobody has
  # watched stay shut is merely believed to be gated, not proven to be. Same
  # real server, same real socket, `AUTODEV_WARDEN_TEST_LOGIN_EMAIL` simply
  # never set: `/stream` sits behind Devise's `authenticate_user!`
  # (`ApplicationController`, unconditional since the PR3 SSO gate —
  # `StreamController` never opts out), so an unauthenticated GET must be
  # refused rather than answered with the live stream.
  #
  # What "refused" actually looks like here, and why this doesn't assert a
  # clean redirect: every *other* gated route answers an unauthenticated GET
  # with a plain `302` to `/sign_in` (verified directly against `GET /`
  # against this same harness). `/stream` does not — `StreamController`
  # includes `ActionController::Live`, which runs the action (and therefore
  # `authenticate_user!`) on a second thread, so Warden's `throw(:warden, …)`
  # has no `catch(:warden)` on that thread to reach, and it surfaces as an
  # uncaught throw instead of the redirect. That is a **separate, real
  # defect** this ticket does not fix (flagged in AGENT-REPORT.md as a
  # finding, not addressed here) — but it still proves the point this test
  # exists for: `authenticate_user!` ran and refused the request, the stream
  # never opened, and the shortcut did not authenticate anything on its own.
  # The assertion accepts either shape (the clean redirect, in case the Live
  # defect is fixed later) so this test does not silently start asserting a
  # bug as permanent.
  def test_the_warden_test_login_is_inert_when_its_env_var_is_unset
    with_real_server(login_email: nil) do |_pid, port|
      response = fetch_response(port)

      refute_match(%r{\AHTTP/1\.1 200}, response,
                   'GET /stream answered 200 with no AUTODEV_WARDEN_TEST_LOGIN_EMAIL set — ' \
                   'the login shortcut authenticates requests on its own, unconditionally')
      assert_match(/sign_in|uncaught throw.*warden|UncaughtThrowError/i, response,
                   'expected evidence that Devise/Warden actually refused this request (a redirect ' \
                   'to /sign_in, or the known ActionController::Live throw/catch mismatch) — got ' \
                   "something else entirely:\n#{response[0, 500]}")
    end
  end

  # `assert_puma_process` is the one thing standing between "the pid we
  # signal" and "a wrapper we mistook for it" — the exact regression named
  # in the brief. A guard nobody has watched fail is not a guard, so this
  # points it at a real process built to look exactly like the false-pass
  # case: a live pid whose full command line is the un-exec'd wrapper
  # invocation, word for word, `$0=` rather than argv (verified separately
  # that `ps -o command=` reflects a Ruby process's `$0` reassignment on
  # this platform). The un-anchored pattern this replaced (`/puma/`) would
  # have matched this pid too — it contains the substring "puma" same as
  # the real thing — which is exactly the false pass this test exists to
  # rule out.
  def test_assert_puma_process_rejects_a_wrapper_whose_argv_only_mentions_puma
    with_fake_wrapper_process do |pid|
      error = assert_raises(Minitest::Assertion) { assert_puma_process(pid) }

      assert_match(/does not look like a puma process/, error.message)
    end
  end

  private

  # Boots the real app server against a throwaway primary DB + port, yields
  # (pid, port), and guarantees the process is gone afterwards even if the
  # block raises or an assertion fails mid-test — the leak this ticket is
  # itself about.
  def with_real_server(login_email: "sse-shutdown-#{SecureRandom.hex(4)}@example.test")
    Dir.mktmpdir('autodev-sse-shutdown') do |dir|
      port = free_port
      log = File.join(dir, 'puma.log')
      pid = spawn_puma(server_env(dir, port, login_email), log)
      wait_for_port(port, BOOT_TIMEOUT_SECONDS, pid: pid, log: log)
      yield pid, port
    ensure
      reap(pid)
    end
  end

  # Real `mise x ruby -- bundle exec puma -C config/puma.rb`, the app's own
  # server started the way the codebase's toolchain notes say it must be —
  # never a bare `ruby`/`bundle` that would resolve to a Ruby whose gems
  # aren't installed.
  def spawn_puma(env, log)
    Process.spawn(env, 'mise', 'x', 'ruby@4.0.1', '--', 'bundle', 'exec', 'puma', '-C', 'config/puma.rb',
                  chdir: APP_ROOT, out: log, err: log)
  end

  def server_env(dir, port, login_email)
    env = {
      'RAILS_ENV' => 'test',
      'AUTODEV_DB' => File.join(dir, 'primary.sqlite3'),
      'AUTODEV_QUEUE_DB' => ':memory:',
      'AUTODEV_SKIP_AUTO_MIGRATE' => '1',
      'PORT' => port.to_s,
      # Always on: both cases need config/environments/test.rb's migration
      # half (see there) — the negative case is a request against a real
      # `sessions` table just as much as the positive one is.
      'AUTODEV_SSE_TEST_HARNESS' => '1'
    }
    env['AUTODEV_WARDEN_TEST_LOGIN_EMAIL'] = login_email if login_email
    env
  end

  # A GET whose response is never fully read and whose socket is never
  # closed by us until teardown — the shape of an open EventSource tab.
  # Draining in a background thread keeps it from ever registering as a
  # dead peer via a failed write (heartbeats every 5s — StreamController's
  # HEARTBEAT_INTERVAL), which is the whole point: this client is *live*,
  # not silently gone, and the only two existing SSE fixes (alpha-5's
  # queue timeout, alpha-16's pagehide listener) both target a *dead*
  # client, not this one.
  def open_stream_connection(port)
    socket = TCPSocket.new('127.0.0.1', port)
    status_line = request_stream(socket)

    assert_match(%r{\AHTTP/1\.1 200}, status_line, 'GET /stream did not return 200 — client never really attached')

    Thread.new do
      loop { socket.readpartial(4096) }
    rescue StandardError
      nil # socket closed at teardown, or the server went away — either ends the drain loop
    end

    socket
  end

  # A one-shot GET, for the negative case: nothing is left open, there is no
  # live stream to hold — just whether, and how, the server refused it.
  def fetch_response(port)
    socket = TCPSocket.new('127.0.0.1', port)
    socket.write(PROBE_REQUEST)
    socket.read
  ensure
    socket&.close
  end

  def request_stream(socket)
    socket.write(STREAM_REQUEST)
    socket.gets
  end

  def free_port
    server = TCPServer.new('127.0.0.1', 0)
    server.addr[1]
  ensure
    server&.close
  end

  # A real, live process whose `ps -o command=` output is, word for word,
  # what an un-exec'd `mise x … bundle exec puma …` wrapper's own argv would
  # show — built with `$0=` rather than by actually invoking mise/bundle,
  # since the point is the string `assert_puma_process` reads, not a real
  # toolchain round-trip. A readiness file avoids racing `$0=` (it runs
  # before anything else, but `ps` could still catch the process mid-spawn).
  def with_fake_wrapper_process
    Dir.mktmpdir('autodev-fake-wrapper') do |dir|
      ready = File.join(dir, 'ready')
      script = "$0 = 'mise x ruby@4.0.1 -- bundle exec puma -C config/puma.rb'; " \
               "File.write(#{ready.inspect}, 'ok'); sleep 30"
      pid = Process.spawn(RbConfig.ruby, '-e', script)
      wait_for_readiness(ready)
      yield pid
    ensure
      reap(pid)
    end
  end

  def wait_for_readiness(path, timeout: 5)
    deadline = monotonic_now + timeout
    sleep 0.02 until File.exist?(path) || monotonic_now > deadline
    raise "fake wrapper process never became ready (#{path})" unless File.exist?(path)
  end

  def wait_for_port(port, timeout, pid:, log:)
    deadline = monotonic_now + timeout
    loop do
      TCPSocket.new('127.0.0.1', port).close
      return
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET
      raise "puma (pid=#{pid}) exited before ever accepting a connection:\n#{File.read(log)}" if process_gone?(pid)
      raise "puma never accepted a connection on port #{port}:\n#{File.read(log)}" if monotonic_now >= deadline

      sleep 0.1
    end
  end

  # Confirms the pid we are about to signal really is puma, not a `bundle
  # exec` / `mise x` wrapper — signalling the wrapper and reading its exit
  # as puma's would "prove" the opposite of the truth. `Process.spawn`'s
  # return value is already the real process (verified empirically, see
  # AGENT-REPORT.md); this is the belt-and-suspenders check on that fact.
  #
  # Anchored at the start of the command on purpose (see `PUMA_COMMAND_PATTERN`
  # up top): puma renames its own argv to start with "puma …" (`$0=`, visible
  # in `ps`), but an un-exec'd wrapper's argv *also contains the word "puma"*
  # as one of its own arguments — `mise x ruby@4.0.1 -- bundle exec puma -C
  # config/puma.rb` matches a bare `/puma/` just as well as the real thing
  # does. Only the anchor tells them apart; see the teeth proof
  # (`test_assert_puma_process_rejects_a_wrapper_whose_argv_only_mentions_puma`).
  def assert_puma_process(pid)
    command = `ps -o command= -p #{pid}`.strip

    assert_match(PUMA_COMMAND_PATTERN, command,
                 "pid #{pid} does not look like a puma process (ps: #{command.inspect})")
  end

  # nil while the process is still alive; the exit `Process::Status` once
  # `Process.wait2` reaps it, or once `timeout` seconds have passed.
  def wait_for_exit(pid, timeout)
    deadline = monotonic_now + timeout
    loop do
      _reaped_pid, status = Process.wait2(pid, Process::WNOHANG)
      return status if status
      return nil if monotonic_now >= deadline

      sleep 0.2
    end
  end

  def process_gone?(pid)
    Process.kill(0, pid) && false
  rescue Errno::ESRCH
    true
  end

  # Reaps whatever survives — the leak this ticket is itself about.
  def reap(pid)
    return if process_gone?(pid)

    Process.kill('KILL', pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
# rubocop:enable Metrics/ClassLength
