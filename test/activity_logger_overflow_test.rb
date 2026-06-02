# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/activity_logger'

# Regression tests for the activity note overflow incident: issues stuck in
# checking_pipeline (per the "no blocked state" design) used to append a fresh
# line to the activity note on every poll for pipeline_red / pipeline_infra,
# eventually blowing past GitLab's 1M-char note cap and breaking every
# subsequent activity update with a 400.
class ActivityLoggerOverflowTest < Minitest::Test
  FakeIssue = Struct.new(:locale)

  # -- replace_or_append --

  def test_replace_or_append_replaces_match_not_at_tail
    pattern = /infra/
    body = "header\n- 01-01 09:00 — :warning: infra\n- 01-01 09:05 — :mag: poll"
    entry = '- 01-01 09:10 — :warning: infra'

    result = ActivityLogger.send(:replace_or_append, body, entry, pattern)

    assert_equal "header\n- 01-01 09:05 — :mag: poll\n- 01-01 09:10 — :warning: infra", result
  end

  def test_replace_or_append_appends_when_no_match
    pattern = /no-such-line/
    body = "header\n- 01-01 09:00 — :mag: poll"
    entry = '- 01-01 09:10 — :rocket: done'

    result = ActivityLogger.send(:replace_or_append, body, entry, pattern)

    assert_equal "#{body}\n#{entry}", result
  end

  def test_replace_or_append_keeps_only_most_recent_match
    pattern = /infra/
    body = (1..5).map { |i| "- line #{i} infra" }.join("\n")
    entry = '- new infra'

    result = ActivityLogger.send(:replace_or_append, body, entry, pattern)
    lines = result.split("\n")

    assert_equal 5, lines.length, 'one old line removed, new one appended'
    assert_equal '- new infra', lines.last
    assert_includes lines, '- line 4 infra', 'only the very last match is dropped'
  end

  # -- enforce_size_cap --

  def test_enforce_size_cap_brings_oversized_body_under_the_limit
    result = ActivityLogger.send(:enforce_size_cap, oversized_body, FakeIssue.new('fr'))

    assert_operator result.length, :<=, ActivityLogger::MAX_NOTE_BYTES
  end

  def test_enforce_size_cap_preserves_header
    result = ActivityLogger.send(:enforce_size_cap, oversized_body, FakeIssue.new('fr'))

    assert result.start_with?("Header line 1\n")
  end

  def test_enforce_size_cap_keeps_most_recent_tail
    result = ActivityLogger.send(:enforce_size_cap, oversized_body, FakeIssue.new('fr'))

    assert_includes result.split("\n").last, 'recent', 'tail-most lines kept'
  end

  def test_enforce_size_cap_is_idempotent
    issue = FakeIssue.new('fr')
    header = ['Header', '']
    big = Array.new(30_000) { |i| "- entry #{i}" }
    body = (header + big).join("\n")

    once = ActivityLogger.send(:enforce_size_cap, body, issue)
    twice = ActivityLogger.send(:enforce_size_cap, "#{once}\n- one more entry", issue)

    marker_count = twice.scan('[anciennes entrees tronquees').size

    assert_equal 1, marker_count, 're-truncation must not stack the marker'
    assert_operator twice.length, :<=, ActivityLogger::MAX_NOTE_BYTES
    assert twice.end_with?('- one more entry'), 'newest entry is kept at the bottom'
  end

  def test_enforce_size_cap_uses_english_marker_for_en_locale
    body = (['Header', ''] + Array.new(30_000) { |i| "- entry #{i}" }).join("\n")

    result = ActivityLogger.send(:enforce_size_cap, body, FakeIssue.new('en'))

    assert_includes result, '[older entries truncated'
    refute_includes result, '[anciennes entrees'
  end

  private

  def oversized_body
    header = ['Header line 1', '']
    bulk = Array.new(20_000) { |i| "- 01-01 09:00 — line #{i}" }
    extra = Array.new(20_000) { |i| "- 02-01 09:00 — recent #{i}" }
    (header + bulk + extra).join("\n").tap do |body|
      raise 'fixture too small, bump line count' if body.length <= ActivityLogger::MAX_NOTE_BYTES
    end
  end
end
