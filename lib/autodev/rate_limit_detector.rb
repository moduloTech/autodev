# frozen_string_literal: true

require 'date'

# Detects rate-limit messages in claude-code output and parses the reset time
# (when claude includes one in its response). Raises RateLimitError so the
# error handler can pause processing until the quota window rolls over.
module RateLimitDetector
  # claude-code names the exhausted quota in the sentence ("You've hit your
  # limit", "… session limit", "… weekly limit", "… fast limit", "… monthly
  # spend limit", "… org's monthly spend limit"). The qualifier is matched as
  # any one to three words rather than listed (Autodev #127): the list is what
  # went stale — "weekly" was missing, so on 2026-09-24 and 2026-09-26 five
  # rows took the generic failure path, each with a public "echec" comment for
  # a quota. A word may carry an apostrophe ("org's"), and the one in "You've"
  # may be typographic. The generic "rate limit" / "usage limit" phrasings stay.
  PATTERN = /you['’]ve hit your (?:[\w'’-]+ ){0,3}limit|rate limit|usage limit/i
  # Accepts both bare-hour ("6pm") and hour:minute ("11:30am") phrasings, then
  # AM/PM and `(UTC)`. The original `\d{1,2}(am|pm)` lost the minutes silently,
  # which set the pause window to the wrong wall-clock time. A weekly limit
  # more than a day from its reset names the date first ("resets Oct 1, 3am
  # (UTC)", Autodev #127); the hour-only pattern did not match that at all, so
  # the pause fell back to RateLimitError's one-hour default and the row went
  # back into the limit every hour until the reset.
  RESET_PATTERN = /resets?\s+(?:([a-z]{3,9})\.?\s+(\d{1,2}),?\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(UTC\)/i

  # A dated reset read up to this long after it passed is still this year's —
  # the message was written before it passed, and `wait_seconds` floors the
  # pause at 60s — last year's too, for a "Dec 31" read on January 1st. Past
  # that, the date is next year's (a December message naming January).
  PASSED_GRACE = 86_400

  module_function

  def check!(stdout, stderr, now: Time.now.utc)
    combined = "#{stdout}\n#{stderr}"
    return unless combined.match?(PATTERN)

    reset_time = parse_reset_time(combined, now: now)
    raise RateLimitError.new("API rate limit reached#{reset_suffix(reset_time, now)}", reset_time: reset_time)
  end

  def reset_suffix(reset_time, now)
    return '' unless reset_time

    format = reset_time - now >= 86_400 ? '%Y-%m-%d %H:%M UTC' : '%H:%M UTC'
    " (resets #{reset_time.strftime(format)})"
  end

  def parse_reset_time(text, now: Time.now.utc)
    match = text.match(RESET_PATTERN)
    return nil unless match

    hour = convert_to_24h(match[3].to_i, match[5].downcase)
    minute = match[4].to_i
    return nil unless hour && minute < 60
    return dated_reset(match[1], match[2].to_i, hour, minute, now) if match[1]

    next_occurrence(hour, minute, now)
  end

  def next_occurrence(hour, minute, now)
    reset = Time.utc(now.year, now.month, now.day, hour, minute, 0)
    reset += 86_400 if reset <= now # next day if already past
    reset
  end

  # nil for a month name nobody spells that way or a day the month does not
  # have: the caller's default pause is a better answer than a date `Time.utc`
  # would silently normalise (Feb 30 → Mar 2).
  def dated_reset(month_name, day, hour, minute, now)
    month = month_number(month_name)
    return nil unless month

    [now.year - 1, now.year, now.year + 1].each do |year|
      next unless Date.valid_date?(year, month, day)

      reset = Time.utc(year, month, day, hour, minute, 0)
      return reset if reset > now - PASSED_GRACE
    end
    nil
  end

  # "Oct", "Sept", "October": a prefix of the English month name, three
  # letters at least.
  def month_number(name)
    index = Date::ABBR_MONTHNAMES.index(name[0, 3].capitalize)
    return nil unless index && Date::MONTHNAMES[index].downcase.start_with?(name.downcase)

    index
  end

  # nil for an hour a 12-hour clock does not have ("13pm", "0am"): `Time.utc`
  # would raise ArgumentError, and a quota would take the failure path again.
  def convert_to_24h(hour, ampm)
    return nil unless (1..12).cover?(hour)

    hour += 12 if ampm == 'pm' && hour != 12
    hour = 0 if ampm == 'am' && hour == 12
    hour
  end
end
