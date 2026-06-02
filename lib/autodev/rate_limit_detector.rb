# frozen_string_literal: true

# Detects rate-limit messages in claude-code output and parses the reset time
# (when claude includes one in its response). Raises RateLimitError so the
# error handler can pause processing until the quota window rolls over.
module RateLimitDetector
  # claude-code emits several variants ("You've hit your limit", "You've hit
  # your session limit", "You've hit your usage limit"). Match all of them
  # plus the generic "rate limit" / "usage limit" phrasings.
  PATTERN = /you've hit your (?:session |usage )?limit|rate limit|usage limit/i
  # Accepts both bare-hour ("6pm") and hour:minute ("11:30am") phrasings, then
  # AM/PM and `(UTC)`. The original `\d{1,2}(am|pm)` lost the minutes silently,
  # which set the pause window to the wrong wall-clock time.
  RESET_PATTERN = /resets?\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(UTC\)/i

  module_function

  def check!(stdout, stderr)
    combined = "#{stdout}\n#{stderr}"
    return unless combined.match?(PATTERN)

    reset_time = parse_reset_time(combined)
    suffix = reset_time ? " (resets #{reset_time.strftime('%H:%M UTC')})" : ''
    raise RateLimitError.new("API rate limit reached#{suffix}", reset_time: reset_time)
  end

  def parse_reset_time(text)
    match = text.match(RESET_PATTERN)
    return nil unless match

    hour = convert_to_24h(match[1].to_i, match[3].downcase)
    minute = match[2] ? match[2].to_i : 0
    now = Time.now.utc
    reset = Time.utc(now.year, now.month, now.day, hour, minute, 0)
    reset += 86_400 if reset <= now # next day if already past
    reset
  end

  def convert_to_24h(hour, ampm)
    hour += 12 if ampm == 'pm' && hour != 12
    hour = 0 if ampm == 'am' && hour == 12
    hour
  end
end
