# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'

# The `mr_review_token` health card (Autodev #80).
#
# `HealthReport` is passive by contract — it never calls GitLab — so this reads
# the verdict `Autodev::MrReviewTokenProbe` recorded during the poll cycle,
# exactly as `check_claude_usage` reads `UsageGate`'s and `check_review_skill`
# reads the skill probe's.
#
# One tier, and only one: `warn`, never `down`. A dead review credential stops
# reviews, not delivery, so `/healthz` must keep answering 200 for the uptime
# probe while the JSON body carries the warn for a secondary alert — the same
# ruling `mr_review` and `review_skill` already carry. The endpoint is exercised
# here rather than assumed, which is why this case runs as an integration test.
#
# And only `revoked` raises it. `unknown` — GitLab unreachable, the credential
# unreadable, or a verdict older than its TTL — is no news, and telling an
# operator their credential is dead because of an outage is the Autodev #62
# mistake in another costume.
class HealthReportMrReviewTokenTest < ActionDispatch::IntegrationTest
  CONFIG = { 'poll_interval' => 300 }.freeze

  def record(status, source: 'gitlab_token', age_seconds: 0)
    ActivityEvent.create!(
      issue_id: nil, kind: Autodev::MrReviewTokenProbe::KIND,
      level: status == 'revoked' ? 'warn' : 'info',
      payload_json: JSON.generate(status: status, source: source),
      created_at: Time.now.utc - age_seconds
    )
  end

  def card(config: CONFIG)
    Autodev::HealthReport.new(config: config).check(:mr_review_token)[:checks][:mr_review_token]
  end

  test 'the card is one of the report checks' do
    assert_includes Autodev::HealthReport::CHECKS, :mr_review_token
  end

  # The state of the fleet today: both projects declare a review skill, so the
  # probe never runs and there is nothing on file. That is not a fault.
  test 'ok when nothing was ever probed' do
    assert_equal :ok, card[:status]
  end

  test 'ok when the credential was accepted' do
    record('alive')

    assert_equal :ok, card[:status]
  end

  test 'warn when the credential was rejected' do
    record('revoked')

    assert_equal :warn, card[:status]
  end

  test 'the warn names the key the credential comes from, without its value' do
    record('revoked', source: 'mr_review_token')

    assert_equal 'mr_review_token', card[:meta][:source]
  end

  # A read that failed is not a verdict on the credential (Autodev #62).
  test 'ok when the last probe could not tell' do
    record('unknown')

    assert_equal :ok, card[:status]
  end

  # Two poll intervals, floor ten minutes. Past that the verdict is not evidence
  # of anything any more, and the default is to fail open.
  test 'ok when the last verdict is older than its ttl' do
    record('revoked', age_seconds: 3600)

    assert_equal :ok, card[:status]
  end

  test 'the card never reaches the paging tier' do
    record('revoked')
    report = Autodev::HealthReport.new(config: CONFIG).call

    assert_equal :warn, report[:checks][:mr_review_token][:status]
  end

  # The property the tier exists for, through the real endpoint: a rejected
  # review credential must not take the uptime probe red.
  test 'healthz still answers 200 with the warn in its body' do
    record('revoked')

    get '/healthz/mr_review_token'

    assert_response :ok
    assert_equal 'warn', JSON.parse(response.body)['status']
  end
end
