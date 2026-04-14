# frozen_string_literal: true

require 'open3'

# Proactive Claude CLI usage check.
# Runs a minimal `claude` command before each poll cycle to detect exhausted
# quotas early, avoiding wasted clones and partial work.
class UsageChecker
  CACHE_TTL = 300 # seconds — avoid spamming the CLI every poll cycle
  RATE_LIMIT_PATTERN = DangerClaudeRunner::RATE_LIMIT_PATTERN

  def initialize(logger:, cache_ttl: CACHE_TTL)
    @logger = logger
    @cache_ttl = cache_ttl
    @available = true
    @checked_at = nil
  end

  def available?
    return @available if @checked_at && (Time.now - @checked_at) < @cache_ttl

    check!
  end

  private

  def check!
    out, err, status = send_probe
    @checked_at = Time.now
    @available = !rate_limit?(status, "#{out}\n#{err}")
    @logger.warn('Claude usage exhausted, skipping poll cycle') unless @available
    @available
  rescue StandardError => e
    @logger.error("Usage check failed: #{e.message}")
    @checked_at = Time.now
    @available = true # assume available on transient errors
  end

  def rate_limit?(status, output)
    !status.success? && output.match?(RATE_LIMIT_PATTERN)
  end

  def send_probe
    Open3.capture3(DangerClaudeRunner::CLEAN_ENV,
                   'danger-claude', '-p', 'ok', '--max-turns', '1',
                   stdin_data: '.')
  end
end
