# frozen_string_literal: true

require_relative '../../../autodev_test_helper'

# A Claude 401 surfaces as an AuthenticationError, stored with its class name in
# error_message by the workers' handle_auth_failure. The watch card (now on the
# /issues?tab=errors list, rendered via the WatchCards mixin) must then show the
# dedicated "no longer connected to Claude" message and drop the retry button
# (retrying never helps until credentials are restored), instead of the generic
# "Échec technique" copy with a "Réessayer maintenant" button.
class ErrorsAuthFailureTest < ActiveSupport::TestCase
  include DatabaseTestHelper

  def setup
    setup_database
  end

  # Render the errors tab of the issues list for a single issue. Exercises the
  # exact path the dashboard now uses: Web::Views::Issues + WatchCards.
  def render_for(issue, admin: false)
    Web::Views::Issues.new(
      issues: [issue], total: 1, total_pages: 1, page: 1, per_page: 50,
      filters: {}, tab: 'errors', tab_counts: Hash.new(0), kpis: Hash.new(0),
      closable_ids: Set.new, current_user_admin: admin
    ).call
  end

  def test_auth_failure_shows_dedicated_message
    issue = create_issue(status: 'error',
                         error_message: 'AuthenticationError: danger-claude can no longer authenticate')
    html = render_for(issue)

    assert_includes html, 'plus connecté à Claude'
  end

  def test_auth_failure_hides_retry_button_for_regular_users
    issue = create_issue(status: 'error',
                         error_message: 'AuthenticationError: danger-claude can no longer authenticate')
    html = render_for(issue)

    refute_includes html, "/issues/#{issue.id}/reset"
  end

  def test_auth_failure_keeps_retry_button_for_admins
    # Admins can re-kick the issue once they've restored the Claude credentials.
    issue = create_issue(status: 'error',
                         error_message: 'AuthenticationError: danger-claude can no longer authenticate')
    html = render_for(issue, admin: true)

    assert_includes html, "/issues/#{issue.id}/reset"
  end

  def test_generic_error_keeps_retry_button_and_message
    issue = create_issue(status: 'error', error_message: "NoMethodError: undefined method 'foo'")
    html = render_for(issue)

    assert_includes html, "/issues/#{issue.id}/reset"
    assert_includes html, 'a empêché autodev de continuer'
  end

  def test_error_alert_keeps_red_tone
    issue = create_issue(status: 'error', error_message: "NoMethodError: undefined method 'foo'")
    html = render_for(issue)

    refute_includes html, 'cause-panel--warn'
  end
end
