# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'

# The errors-tab "Réessayer maintenant" button ships a
# `return_to=/issues?tab=errors` hidden field so a reset bounces back to the
# errors list (mass retry) instead of each issue's detail page. The default (no
# return_to, e.g. the issue detail page's own reset button) still lands on the
# issue. Open-redirect attempts are ignored.
class IssuesControllerResetRedirectTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: 'admin@modulotech.fr', name: 'Admin', admin: true)
    @issue = Issue.create!(project_path: 'group/proj', issue_iid: 600, status: 'error',
                           error_message: 'boom', retry_count: 1)
    sign_in @admin
  end

  def test_reset_redirects_to_issue_by_default
    post "/issues/#{@issue.id}/reset"

    assert_redirected_to "/issues/#{@issue.id}"
  end

  def test_reset_redirects_back_to_errors_when_requested
    post "/issues/#{@issue.id}/reset", params: { return_to: '/issues?tab=errors' }

    assert_redirected_to '/issues?tab=errors'
  end

  def test_reset_ignores_offsite_return_to
    post "/issues/#{@issue.id}/reset", params: { return_to: 'https://evil.example.com' }

    assert_redirected_to "/issues/#{@issue.id}"
  end

  def test_reset_ignores_protocol_relative_return_to
    post "/issues/#{@issue.id}/reset", params: { return_to: '//evil.example.com' }

    assert_redirected_to "/issues/#{@issue.id}"
  end
end
