# frozen_string_literal: true

require_relative '../../../autodev_test_helper'

# The delivered_review tab renders the same watch cards as the errors/waiting
# tabs, but with a "Clôturer" CTA instead of "Réessayer". The close button is
# gated like IssuesController#close: only shown for issues in closable_ids
# (project collaborators + admins); everyone else sees just "Voir le détail".
class DeliveredReviewCardTest < ActiveSupport::TestCase
  include DatabaseTestHelper

  def setup
    setup_database
  end

  def render_for(issue, closable: [])
    Web::Views::Issues.new(
      issues: [issue], total: 1, total_pages: 1, page: 1, per_page: 50,
      filters: {}, tab: 'delivered_review', tab_counts: Hash.new(0),
      kpis: Hash.new(0), closable_ids: closable.to_set
    ).call
  end

  def test_shows_close_button_when_closable
    issue = create_issue(status: 'done', needs_attention: true, attention_reason: 'stagnation_pipeline')
    html = render_for(issue, closable: [issue.id])

    assert_includes html, "/issues/#{issue.id}/close"
    assert_includes html, 'Intervention manuelle requise'
  end

  def test_hides_close_button_when_not_closable
    issue = create_issue(status: 'done', needs_attention: true, attention_reason: 'stagnation_pipeline')
    html = render_for(issue, closable: [])

    refute_includes html, "/issues/#{issue.id}/close"
    assert_includes html, "/issues/#{issue.id}" # the "Voir le détail" link still renders
  end

  def test_post_completion_error_shows_dedicated_cause_and_details
    issue = create_issue(status: 'done', post_completion_error: 'deploy script failed')
    html = render_for(issue, closable: [issue.id])

    assert_includes html, 'Erreur post-completion'
    assert_includes html, 'deploy script failed'
  end

  def test_alert_uses_warn_tone_not_red
    issue = create_issue(status: 'done', needs_attention: true, attention_reason: 'stagnation_pipeline')
    html = render_for(issue, closable: [issue.id])

    assert_includes html, 'cause-panel--warn'
  end
end
