# frozen_string_literal: true

# This configuration file will be evaluated by Puma. The top-level methods that
# are invoked here are part of Puma's configuration DSL. For more information
# about methods provided by the DSL, see https://puma.io/puma/Puma/DSL.html.
#
# Puma starts a configurable number of processes (workers) and each process
# serves each request in a thread from an internal thread pool.
#
# You can control the number of workers using ENV["WEB_CONCURRENCY"]. You
# should only set this value when you want to run 2 or more workers. The
# default is already 1. You can set it to `auto` to automatically start a worker
# for each available processor.
#
# The ideal number of threads per worker depends both on how much time the
# application spends waiting for IO operations and on how much you wish to
# prioritize throughput over latency.
#
# As a rule of thumb, increasing the number of threads will increase how much
# traffic a given process can handle (throughput), but due to CRuby's
# Global VM Lock (GVL) it has diminishing returns and will degrade the
# response time (latency) of the application.
#
# The default is set to 3 threads as it's deemed a decent compromise between
# throughput and latency for the average Rails application.
#
# Any libraries that use a connection pool or another resource pool should
# be configured to provide at least as many connections as the number of
# threads. This includes Active Record's `pool` parameter in `database.yml`.
# Bumped from 3 → 10: every open browser tab parks one thread on
# /stream (SSE via ActionController::Live). With the previous 3-thread
# pool, a few concurrent tabs / reloads could exhaust the pool and
# freeze the dashboard until next activity unwedged a thread.
# StreamController's heartbeat now frees threads tied to dead tabs,
# but a higher floor gives headroom for concurrent tabs + the few
# non-SSE controller hits a page load fans out to.
threads_count = ENV.fetch('RAILS_MAX_THREADS', 10)
threads threads_count, threads_count

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
port ENV.fetch('PORT', 3000)

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

# Specify the PID file. Defaults to tmp/pids/server.pid in development.
# In other environments, only set the PID file if requested.
pidfile ENV['PIDFILE'] if ENV['PIDFILE']

# Autodev #112: an open `/stream` connection (SSE via `ActionController::Live`,
# see `StreamController`) never releases its Puma thread on its own — a tab
# left open holds it for the tab's whole lifetime by design (alpha-16
# changelog entry). `force_shutdown_after` is unset by default (absent from
# Puma's own defaults, confirmed in this gem version — puma 6.6.1,
# `lib/puma/server.rb:604-609`), so `graceful_shutdown` calls
# `@thread_pool.shutdown` with **no timeout** when a thread is still parked
# there: a SIGTERM closed the port at once (the next process could bind it)
# but left the old process running, holding `~/.autodev/autodev.db`, its WAL
# and its shared-memory file open for writing — reproduced locally (a client
# attached to `/stream` kept the process alive at least 16s post-SIGTERM with
# no cap) and measured in production holding the database for 40 minutes on
# 03/09/2026.
#
# 2 seconds — not the 5 this ticket's own brief proposed, which the code
# ruled out. `force_shutdown_after` is not the whole wait: once it elapses,
# `Puma::ThreadPool#shutdown` raises `ForceShutdown` in the stuck thread and
# then waits a **second**, fixed grace period — `SHUTDOWN_GRACE_TIME = 5`
# seconds (`lib/puma/thread_pool.rb:26`), settable only via the
# undocumented `pool_shutdown_grace_time` option ("Not an 'exposed' option
# ... used in CI", same file) and reachable from nowhere in the public DSL
# `config/puma.rb` speaks — before it finally kills the thread and waits up
# to 1 more second. Measured against a real client attached to `/stream`,
# with `Process.clock_gettime` around a real `SIGTERM` (see
# `test/sse_shutdown_test.rb` / AGENT-REPORT.md for the harness):
# `force_shutdown_after` → total time to exit was `:immediately`(0) → 5.1s,
# `1` → 6.1s, `2` → 7.1s, `3` → 8.1s, `5` → 10.2s. The relationship is
# `force_shutdown_after + ~5.1s`, not `force_shutdown_after` alone.
#
# `Autodev::Supervisor::TERM_GRACE_SECONDS` is 10: the supervisor KILLs a
# straggler after that, so Puma must exit *inside* the window or every
# ordinary shutdown — not only one with a stuck SSE thread — ends in a KILL
# instead of a drain. The brief's 5 measures out at ~10.2s, past the
# supervisor's own ceiling more often than not; `2` measures at ~7.1s,
# leaving close to 3s of margin against process-scheduling jitter on top of
# this dev machine's own numbers. launchd's `ExitTimeOut` defaults to 20s
# with no override in the production plist (read on bobette, 04/09/2026),
# so either number clears that bound easily — the supervisor's 10s is the
# binding constraint, not launchd's.
#
# Why 2 and not lower: `:immediately`/`1` would buy more margin against the
# supervisor's ceiling, but neither is chosen for that. 2s does not
# comfortably cover every request this app serves, and the neutral review of
# the alpha-54 lot is right to say so: `IssuesController#reset` (via
# `Autodev::ResetReclaim.perform`) makes two synchronous GitLab writes
# in-request — repose the working label, then reclaim the assignment — and
# `DeployReviewsController#index` fetches merge requests from GitLab
# synchronously too; either can outlast 2s on a slow link. `ForceShutdown`
# landing between `ResetReclaim`'s two writes leaves the reclaim
# half-applied. One direction only, and not unattended: `perform` reposes
# the label and then reclaims, so the reachable half is a reposed label
# with the assignment not taken, and `ResetReclaim#reclaim` rescues
# `StandardError` — which `ForceShutdown` is, `< RuntimeError` in
# `puma/thread_pool.rb:20` — to put the attention label back before
# re-raising. That repair is itself a GitLab write on a process being
# torn down, so it is an attempt rather than a guarantee. The choice of 2 stands
# anyway: most requests this app serves ARE ordinary dashboard renders
# (milliseconds), the alternative this ticket exists to fix is an unbounded
# hang, and cutting an occasional slow reclaim mid-write is the trade that
# choice makes, not one it hides. Going lower would trade real-work safety
# for margin the measurements above show is already sufficient.
force_shutdown_after 2
