# frozen_string_literal: true

require_relative 'autodev_test_helper'

# Autodev #86 (truthfulness review). `--errors` lists every `needs_attention`
# row under the gave-up-and-delivered group, and `ClarificationWatch` now flags
# questions that are still parked. Nothing was delivered there, so the entry
# says which state the row is in; a delivered give-up prints as before.
class TheErrorsCliSaysAFlaggedQuestionIsStillWaitingTest < ActiveSupport::TestCase
  include DatabaseTestHelper

  def setup
    setup_database
  end

  def printed
    out = StringIO.new
    $stdout = out
    Dashboard::ErrorDisplay.print_all({}, Pastel.new(enabled: false))
    out.string
  ensure
    $stdout = STDOUT
  end

  def test_a_flagged_parked_question_prints_its_status
    create_issue(status: 'needs_clarification', needs_attention: true, attention_reason: 'clarification_reassigned')

    assert_includes printed, 'Statut: needs_clarification'
  end

  def test_a_delivered_give_up_prints_no_status_line
    create_issue(status: 'done', needs_attention: true, attention_reason: 'stagnation_pipeline')

    refute_includes printed, 'Statut:'
  end
end
