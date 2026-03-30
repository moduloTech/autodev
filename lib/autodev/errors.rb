# frozen_string_literal: true

class AutodevError < StandardError; end
class ConfigError < AutodevError; end
class GitError < AutodevError; end
class ImplementationError < AutodevError; end

class RateLimitError < AutodevError
  attr_reader :reset_time

  # Parse "resets Xpm (UTC)" or "resets Xam (UTC)" from the message
  def initialize(message, reset_time: nil)
    @reset_time = reset_time
    super(message)
  end

  # Seconds until the rate limit resets (minimum 60s)
  def wait_seconds
    return 3600 unless @reset_time

    now = Time.now.utc
    diff = @reset_time - now
    diff > 60 ? diff.ceil : 60
  end
end
