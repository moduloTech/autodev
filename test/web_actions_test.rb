# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'web_test_helper'

class WebActionsTest < Minitest::Test
  include Rack::Test::Methods
  include DatabaseTestHelper
  include WebServerTestSetup

  def test_post_reset_redirects
    issue = create_issue(status: 'error', error_message: 'oops')
    post "/issues/#{issue.id}/reset"

    assert_equal 302, last_response.status
  end

  def test_post_reset_clears_error_state
    issue = create_issue(status: 'error', error_message: 'oops', retry_count: 3)
    post "/issues/#{issue.id}/reset"
    reloaded = Issue[issue.id]

    assert_equal %w[pending 0], [reloaded.status, reloaded.retry_count.to_s]
    assert_nil reloaded.error_message
  end

  def test_post_transition_with_permitted_event_succeeds
    issue = create_issue
    post "/issues/#{issue.id}/transition", { event: 'start_processing' }

    assert_equal 'cloning', Issue[issue.id].status
  end

  def test_post_transition_rejects_non_permitted_event
    issue = create_issue
    post "/issues/#{issue.id}/transition", { event: 'pipeline_failed_code' }

    assert_equal 422, last_response.status
  end

  def test_post_transition_does_not_change_state_on_rejection
    issue = create_issue
    post "/issues/#{issue.id}/transition", { event: 'pipeline_failed_code' }

    assert_equal 'pending', Issue[issue.id].status
  end

  def test_post_transition_rejects_unknown_event
    issue = create_issue
    post "/issues/#{issue.id}/transition", { event: 'totally_made_up' }

    assert_equal 422, last_response.status
  end
end
