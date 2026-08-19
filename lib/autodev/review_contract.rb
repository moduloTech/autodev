# frozen_string_literal: true

require 'json'

# What the project's review skill hands back (Autodev #74).
#
# A file rather than stdout: `capture_session_and_text` already parses stdout for
# the session id, a skill's prose legitimately contains fenced code blocks, and a
# truncated stdout would read as an empty review — that is, as a clean MR. That is
# the failure family Autodev #62 exists to remove. A missing or off-schema file is
# an unambiguous failure instead.
class ReviewContract
  class InvalidError < AutodevError; end

  VERDICTS = %w[approve changes_requested].freeze
  SEVERITIES = %w[error warning info nitpick].freeze
  # What both project skills call blocking-class.
  BLOCKING = %w[error warning].freeze

  attr_reader :verdict, :summary, :inline, :summary_only

  def self.parse(raw)
    data = JSON.parse(raw.to_s)
    raise InvalidError, 'contract is not a JSON object' unless data.is_a?(Hash)

    new(data)
  rescue JSON::ParserError => e
    raise InvalidError, "contract is not valid JSON: #{e.message}"
  end

  def initialize(data)
    @verdict = data['verdict']
    raise InvalidError, "verdict must be one of #{VERDICTS.join(', ')}" unless VERDICTS.include?(@verdict)

    @summary = data['summary'].to_s
    findings = data['findings'] || []
    raise InvalidError, 'findings must be an array' unless findings.is_a?(Array)

    validate_severities!(findings)
    @inline, @summary_only = findings.partition { |f| inline?(f) }
  end

  private

  # The one rule: anchorable AND blocking-class.
  def inline?(finding)
    BLOCKING.include?(finding['severity']) &&
      !finding['file'].to_s.strip.empty? &&
      finding['line'].to_s.match?(/\A\d+\z/)
  end

  def validate_severities!(findings)
    findings.each do |f|
      raise InvalidError, 'each finding must be an object' unless f.is_a?(Hash)
      raise InvalidError, "unknown severity #{f['severity'].inspect}" unless SEVERITIES.include?(f['severity'])
    end
  end
end
