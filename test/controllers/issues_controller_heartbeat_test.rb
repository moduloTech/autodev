# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'

# The issue timeline must not show danger-claude liveness markers (Autodev #50).
# They are written once per call — a single implementation run can produce a
# dozen — and carry no message anyone asked for. The activity count in the
# section heading is rendered from the same list, so it is the assertion that
# pins the filtering rather than the markup.
class IssuesControllerHeartbeatTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: 'admin@modulotech.fr', name: 'Admin', admin: true)
    @issue = Issue.create!(project_path: 'group/proj', issue_iid: 600, status: 'implementing')
    # `danger_claude` is the kind whose Web::Helpers#format_event branch reads
    # payload['message'] verbatim — 'transition' renders a from/to/event
    # summary and would ignore this payload shape entirely, making the
    # 'visible-entry' assertion below pass or fail for reasons unrelated to
    # heartbeat filtering.
    ActivityEvent.create!(issue_id: @issue.id, kind: 'danger_claude', level: 'info',
                          payload_json: JSON.generate(message: 'visible-entry'))
    2.times do
      ActivityEvent.create!(issue_id: @issue.id, kind: 'heartbeat', level: 'info',
                            payload_json: JSON.generate(event: 'dc_call', label: '-p'))
    end
    sign_in @admin
  end

  def test_timeline_does_not_render_heartbeat_rows
    get "/issues/#{@issue.id}"

    assert_response :success
    # Scoped to the activity table, not the whole page: the layout's SSE
    # reconnect script carries an unrelated JS comment mentioning "heartbeat"
    # (Puma-thread liveness, nothing to do with ActivityEvent#kind), which
    # would otherwise make this assertion fail regardless of the filter.
    activity_table = response.body[%r{<table class="activity-table">.*?</table>}m]

    assert_no_match(/heartbeat/, activity_table)
  end

  # `web_issue_activity` renders as "Activity (%{count})" from the same list, so
  # the heading is where a leaked heartbeat shows up as a number.
  def test_activity_count_ignores_heartbeats
    get "/issues/#{@issue.id}"

    assert_response :success
    assert_match 'visible-entry', response.body
    assert_match(/Activity \(1\)/, response.body)
  end
end
