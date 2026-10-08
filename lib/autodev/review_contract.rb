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

  # The verdict that asks a human (or `MrFixer`) to act, and therefore the one
  # `SkillReviewer#unanchored_verdict?` weighs the publication against. Named
  # because it is now read outside this class, and a string literal in two files
  # is how the two drift.
  CHANGES_REQUESTED = 'changes_requested'
  VERDICTS = ['approve', CHANGES_REQUESTED].freeze
  SEVERITIES = %w[error warning info nitpick].freeze
  # What both project skills call blocking-class.
  BLOCKING = %w[error warning].freeze
  # What a finding is about (Autodev #121): `code` is a defect in how the code
  # does what was asked, `functional` a delivered behaviour that differs from
  # what the ticket asked for — a decision only the requester can take, which
  # `MrFixer` turns into a question on the ticket instead of a correction.
  # Absent reads as `code`, so a skill written before the field keeps working.
  FUNCTIONAL = 'functional'
  CODE = 'code'
  CATEGORIES = [FUNCTIONAL, CODE].freeze

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

  def self.functional?(finding) = finding['category'] == FUNCTIONAL

  # Does the finding carry a line GitLab can pin a thread to?
  def self.anchorable?(finding)
    !finding['file'].to_s.strip.empty? && finding['line'].to_s.match?(/\A\d+\z/)
  end

  private

  # The one rule: blocking-class AND (anchorable OR functional). A functional
  # finding with no line is still a decision somebody has to take, so it becomes
  # a thread — unpositioned, `ReviewPublisher` decides — rather than prose in the
  # summary comment, which `MrFixer` never reads and which holds no delivery
  # (Autodev #121).
  def inline?(finding)
    BLOCKING.include?(finding['severity']) &&
      (self.class.anchorable?(finding) || self.class.functional?(finding))
  end

  def validate_severities!(findings)
    findings.each do |f|
      raise InvalidError, 'each finding must be an object' unless f.is_a?(Hash)
      raise InvalidError, "unknown severity #{f['severity'].inspect}" unless SEVERITIES.include?(f['severity'])
      raise InvalidError, "unknown category #{f['category'].inspect}" unless category_known?(f)
    end
  end

  # Strict like `severity`: a misspelt category would silently turn a product
  # question into a code fix.
  def category_known?(finding) = finding['category'].nil? || CATEGORIES.include?(finding['category'])
end
