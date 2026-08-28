# frozen_string_literal: true

require 'json'

# What the targeted verification pass hands back (Autodev #79).
#
# Same shape and the same reason as `ReviewContract` (Autodev #74): a file
# rather than stdout, because `capture_session_and_text` already parses stdout
# for the session id and a truncated answer would read as *something*. Here the
# stake is sharper still — the only value that closes a review thread is
# `addressed`, so every other outcome, including "the file is not there" and
# "the file is not JSON", has to land on the same side. `parse` raises rather
# than returning a default, and `rejected` is the verdict autodev writes for
# itself when the pass could not be performed at all, so the caller has one type
# to read and no third case to forget.
class VerificationContract
  class InvalidError < AutodevError; end

  ADDRESSED = 'addressed'
  NOT_ADDRESSED = 'not_addressed'
  VERDICTS = [ADDRESSED, NOT_ADDRESSED].freeze

  attr_reader :verdict, :reason

  def self.parse(raw)
    data = JSON.parse(raw.to_s)
    raise InvalidError, 'contract is not a JSON object' unless data.is_a?(Hash)

    new(data['verdict'], data['reason'])
  rescue JSON::ParserError => e
    raise InvalidError, "contract is not valid JSON: #{e.message}"
  end

  # "The check did not happen", expressed in the same vocabulary as "the check
  # said no". The caller has exactly one question to ask (`addressed?`).
  def self.rejected(reason)
    new(NOT_ADDRESSED, reason)
  end

  def initialize(verdict, reason)
    raise InvalidError, "verdict must be one of #{VERDICTS.join(', ')}" unless VERDICTS.include?(verdict)

    @verdict = verdict
    @reason = reason.to_s
  end

  def addressed? = @verdict == ADDRESSED
end
