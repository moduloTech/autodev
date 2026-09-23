# frozen_string_literal: true

require_relative '../../../autodev_test_helper'

# A parked question the watch flagged (Autodev #86) is still a question: the
# card keeps its "Question en attente" headline and its "Voir la question"
# CTA, but its body must say *why* the wait went wrong — otherwise the
# operator reads the same "autodev attend votre réponse" whether or not an
# answer can ever be seen. And the delivery contact line is a lie here:
# nothing was delivered.
class AFlaggedClarificationCardTellsWhyTest < ActiveSupport::TestCase
  include DatabaseTestHelper

  REASONS = %w[clarification_reassigned clarification_label_moved
               clarification_budget_spent clarification_unanswered].freeze
  CONTACT = 'Contactez un développeur du projet pour finaliser cette livraison.'

  def setup
    setup_database
  end

  def render_waiting(issue)
    Web::Views::Issues.new(
      issues: [issue], total: 1, total_pages: 1, page: 1, per_page: 50,
      filters: {}, tab: 'waiting', tab_counts: Hash.new(0),
      kpis: Hash.new(0), closable_ids: Set.new
    ).call
  end

  # Phlex escapes apostrophes and quotes; compare against the same escaping.
  def escaped(text)
    ERB::Util.html_escape(text)
  end

  def fr(key)
    I18n.t(key, locale: :fr, raise: true)
  end

  def test_each_flagged_reason_renders_its_own_explanation
    REASONS.each do |reason|
      issue = create_issue(status: 'needs_clarification', needs_attention: true, attention_reason: reason)
      html = render_waiting(issue)

      assert_includes html, escaped(fr(:"web_errors_explain_attention_#{reason}")), "reason=#{reason}"
      refute_includes html, "web_errors_explain_attention_#{reason}", "raw key rendered for #{reason}"
      refute_includes html, escaped(fr(:web_errors_explain_clarification)), "generic wait text for #{reason}"
    end
  end

  def test_a_flagged_card_keeps_the_question_headline
    REASONS.each do |reason|
      issue = create_issue(status: 'needs_clarification', needs_attention: true, attention_reason: reason)
      html = render_waiting(issue)

      assert_includes html, 'Question en attente', "reason=#{reason}"
      refute_includes html, 'Intervention manuelle requise', "reason=#{reason}"
    end
  end

  def test_a_flagged_card_has_no_delivery_contact_line
    REASONS.each do |reason|
      issue = create_issue(status: 'needs_clarification', needs_attention: true, attention_reason: reason)

      refute_includes render_waiting(issue), CONTACT, "reason=#{reason}"
    end
  end

  def test_an_unflagged_card_keeps_the_waiting_explanation
    html = render_waiting(create_issue(status: 'needs_clarification'))

    assert_includes html, escaped(fr(:web_errors_explain_clarification))
    refute_includes html, CONTACT
  end

  def test_a_flag_without_a_reason_keeps_the_waiting_explanation
    issue = create_issue(status: 'needs_clarification', needs_attention: true, attention_reason: nil)
    html = render_waiting(issue)

    assert_includes html, escaped(fr(:web_errors_explain_clarification))
    refute_includes html, 'web_errors_explain_attention_'
  end

  # A reason from another life (the CLI --reset does not clear attention)
  # still has its own copy; the card must not fall back to a raw key.
  def test_a_foreign_reason_renders_its_existing_explanation
    issue = create_issue(status: 'needs_clarification', needs_attention: true,
                         attention_reason: 'dormant_exhausted')
    html = render_waiting(issue)

    assert_includes html, escaped(fr(:web_errors_explain_attention_dormant_exhausted))
    refute_includes html, 'web_errors_explain_attention_'
    refute_includes html, CONTACT
  end

  # The label may have gone because autodev's own label write failed; the
  # copy must not accuse a human.
  def test_label_moved_does_not_claim_a_human_removed_it
    [fr(:web_errors_explain_attention_clarification_label_moved),
     I18n.t(:web_errors_explain_attention_clarification_label_moved, locale: :en, raise: true)].each do |text|
      refute_match(/quelqu.un|someone|somebody|a human|un humain/i, text)
    end
  end

  def test_the_four_keys_exist_in_fr_and_en_without_variables
    REASONS.each do |reason|
      %i[fr en].each do |locale|
        text = I18n.t(:"web_errors_explain_attention_#{reason}", locale: locale, raise: true)

        refute_includes text, '%{', "#{locale} #{reason}"
      end
    end
  end
end
