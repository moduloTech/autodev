# frozen_string_literal: true

require 'net/http'
require 'json'

# Proactive Claude API usage check.
# Makes a lightweight API call before each poll cycle to detect exhausted quotas
# early, avoiding wasted clones and partial work.
class UsageChecker
  API_URL = URI('https://api.anthropic.com/v1/messages').freeze
  CACHE_TTL = 300 # seconds — avoid hammering the API every poll cycle
  CHECK_MODEL = 'claude-haiku-4-5-20251001'

  def initialize(api_key:, logger:, cache_ttl: CACHE_TTL)
    @api_key = api_key
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
    response = send_probe
    @checked_at = Time.now
    @available = response.code != '429'
    @logger.warn('Claude API usage exhausted (429), skipping poll cycle') unless @available
    @available
  rescue StandardError => e
    @logger.error("Usage check failed: #{e.message}")
    @checked_at = Time.now
    @available = true # assume available on transient errors
  end

  def send_probe
    http = Net::HTTP.new(API_URL.host, API_URL.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 10
    http.request(build_request)
  end

  def build_request
    req = Net::HTTP::Post.new(API_URL)
    req['x-api-key'] = @api_key
    req['anthropic-version'] = '2023-06-01'
    req['content-type'] = 'application/json'
    req.body = JSON.generate(model: CHECK_MODEL, max_tokens: 1,
                             messages: [{ role: 'user', content: '.' }])
    req
  end
end
