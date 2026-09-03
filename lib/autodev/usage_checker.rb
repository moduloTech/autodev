# frozen_string_literal: true

require 'open3'
require_relative 'redactor'
require_relative 'rate_limit_detector'
require_relative 'auth_failure_detector'
require_relative 'usage_probe_spawn'

# Proactive Claude CLI usage check.
#
# Runs a minimal `danger-claude` command before each poll cycle. This is not a
# side probe: it is the same call the whole product depends on to implement,
# review and fix discussions, so a probe that succeeds proves the entire
# chain — the binary is on PATH, the container runtime answers, the volumes
# resolve, the credentials authenticate, the quota is there (Autodev #108).
#
# #verdict answers a typed { status:, diagnostic: } rather than a boolean
# (Autodev #108) — see STATUSES below. Only `broken` carries a diagnostic: the
# recognised causes name themselves, and a Redactor-scrubbed, truncated excerpt
# is kept only for the one status nobody enumerated.
class UsageChecker
  include UsageProbeSpawn

  CACHE_TTL = 300 # seconds — avoid spamming the CLI every poll cycle

  RATE_LIMIT_PATTERN = RateLimitDetector::PATTERN
  AUTH_REFUSED_PATTERN = AuthFailureDetector::PATTERN

  DEFAULT_COMMAND = ['danger-claude', '-p', 'ok', '--max-turns', '1'].freeze

  # 30s. Calibrated on bobette (2026-09-03), not chosen: six times the observed
  # p50 of a successful probe (4.95s), eleven times the p99 of every failing
  # path (2.71s), eighty times the whole-container baseline (375ms), and a
  # quarter of the production `poll_interval` of 120s. A timeout classifies
  # `unknown`, never `broken`: a tool that has not finished answering has not
  # answered, so an over-tight value costs one observation and never a false
  # outage — which is what makes 30s safe to pick from a median rather than
  # from a tail nobody can measure cleanly.
  TIMEOUT = 30

  # TERM the process group, wait, then KILL — ProcessRunner#kill_process_group's
  # sequence, reproduced here rather than shared: this probe carries none of
  # @dc_stdout / @project_config / @port_mappings that method depends on, and it
  # writes to the child's stdin where run_with_timeout spawns with `in: :close`.
  # A bare `Timeout.timeout` around the probe would leave the container running.
  KILL_GRACE = 5

  DIAGNOSTIC_MAX = 1000 # a bounded excerpt for the health card, not the transcript

  # The six verdicts `#verdict` can answer. `available` and `unknown` are the
  # only two the gate reads as "may still spend a call" (Autodev::UsageGate).
  STATUSES = %i[available quota_exhausted auth_refused binary_missing broken unknown].freeze

  # `timeout:`, `kill_grace:` and `command:` are overridable for tests, which
  # spawn real (cheap) subprocesses rather than stub Open3 — the same idiom
  # ProcessRunnerTest uses for run_with_timeout. Production never overrides them.
  def initialize(logger:, cache_ttl: CACHE_TTL, timeout: TIMEOUT, kill_grace: KILL_GRACE,
                 command: DEFAULT_COMMAND)
    @logger = logger
    @cache_ttl = cache_ttl
    @timeout = timeout
    @kill_grace = kill_grace
    @command = command
    @verdict = { status: :available, diagnostic: nil }
    @checked_at = nil
  end

  def verdict
    return @verdict if @checked_at && (Time.now - @checked_at) < @cache_ttl

    check!
  end

  private

  def check!
    out, err, status = send_probe
    stamp!(classify(status, out, err))
  rescue Errno::ENOENT => e
    @logger.error("Usage check failed, danger-claude not on PATH: #{e.message}")
    stamp!({ status: :binary_missing, diagnostic: nil })
  rescue StandardError => e
    @logger.error("Usage check failed: #{e.class}: #{e.message}")
    stamp!({ status: :unknown, diagnostic: nil })
  end

  def stamp!(verdict)
    @checked_at = Time.now
    @verdict = verdict
    @logger.warn("danger-claude probe: #{verdict[:status]}") unless verdict[:status] == :available
    @verdict
  end

  # A non-zero exit is an answer: the tool ran and failed, and what is unknown
  # is why, not whether. Order is fixed (Autodev #108): quota before auth,
  # matching the pre-existing precedence, so an output carrying both signatures
  # keeps reading as the cause that resolves itself. The Docker/API-version
  # outage this ticket exists for carries neither signature and lands on
  # `broken` without any Docker-specific pattern — a pattern would buy a nicer
  # label, not a detection.
  def classify(status, out, err)
    combined = "#{out}\n#{err}"
    return { status: :available, diagnostic: nil } if status.success?
    return { status: :quota_exhausted, diagnostic: nil } if combined.match?(RATE_LIMIT_PATTERN)
    return { status: :auth_refused, diagnostic: nil } if combined.match?(AUTH_REFUSED_PATTERN)

    { status: :broken, diagnostic: Redactor.scrub(combined)[0, DIAGNOSTIC_MAX] }
  end
end
