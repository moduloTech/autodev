# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'

# The `project_briefings` health card (Autodev #117).
#
# A failed briefing refresh used to leave no trace anywhere an operator looks:
# the briefing just grew old. This card reads the staleness of the last
# successful refresh — `briefing_generated_at`, or the project's `created_at`
# when it never had one — against the 6 h figure calibrated on production.
#
# Staleness raises it, not `briefing_error`: one failed hourly run behind a
# fresh briefing is the noise the calibration excludes. And `warn`, never
# `down` — a stale briefing degrades AutoSpec's context, it stops no delivery,
# so `/healthz` must keep answering 200. The endpoint is exercised rather than
# assumed, which is why this runs as an integration test.
class HealthReportProjectBriefingsTest < ActionDispatch::IntegrationTest # rubocop:disable Metrics/ClassLength
  CONFIG = { 'poll_interval' => 300 }.freeze
  # Real time, not a fixed date: `update!` stamps `updated_at` with the clock,
  # and the updated_at cases need that stamp to land inside the window.
  setup { @now = Time.current.change(usec: 0) }

  def project(path, generated_ago: nil, created_ago: 30 * 86_400, error: nil)
    Project.create!(gitlab_path: path, slug: path.tr('/', '_'),
                    created_at: @now - created_ago,
                    briefing_generated_at: generated_ago && (@now - generated_ago),
                    briefing_error: error)
  end

  def card(poller_expected: true)
    report = Autodev::HealthReport.new(config: CONFIG, now: @now, poller_expected: poller_expected)
    report.check(:project_briefings)[:checks][:project_briefings]
  end

  test 'the card is one of the report checks' do
    assert_includes Autodev::HealthReport::CHECKS, :project_briefings
  end

  test 'the staleness figure is the calibrated six hours' do
    assert_equal 6 * 3600, Autodev::HealthReport::BRIEFING_STALE_AFTER
  end

  test 'ok when there is no project' do
    assert_equal :ok, card[:status]
    assert_equal 'no projects', card[:detail]
  end

  test 'ok on a briefing refreshed an hour ago' do
    project('g/fresh', generated_ago: 3600)

    assert_equal :ok, card[:status]
    assert_equal '1 briefing(s) fresh', card[:detail]
  end

  test 'warn on a briefing refreshed seven hours ago, naming the project' do
    project('g/stale', generated_ago: 7 * 3600)

    assert_equal :warn, card[:status]
    assert_equal '1 project briefing(s) not refreshed for over 6h', card[:detail]
    assert_equal ['g/stale (7.0h)'], card[:meta][:sample]
  end

  test 'boundary: 5h59 is fresh' do
    project('g/under', generated_ago: (5 * 3600) + (59 * 60))

    assert_equal :ok, card[:status]
  end

  test 'boundary: 6h01 is stale' do
    project('g/under', generated_ago: (5 * 3600) + (59 * 60))
    project('g/over', generated_ago: (6 * 3600) + 60)

    assert_equal :warn, card[:status]
    assert_equal ['g/over (6.0h)'], card[:meta][:sample]
  end

  # Strict `<`: exactly six hours old is still inside the window.
  test 'boundary: exactly six hours is fresh' do
    project('g/edge', generated_ago: 6 * 3600)

    assert_equal :ok, card[:status]
  end

  test 'a project never refreshed is judged on its creation date' do
    project('g/new', created_ago: 3600)

    assert_equal :ok, card[:status]

    project('g/old', created_ago: 7 * 3600)

    assert_equal :warn, card[:status]
    assert_equal ['g/old (7.0h)'], card[:meta][:sample]
  end

  # Any write to the row moves `updated_at` — a failed refresh storing its
  # error included — so reading it would call every failing project fresh.
  test 'staleness ignores updated_at on a never-refreshed project' do
    stale = project('g/touched', created_ago: 7 * 3600)
    stale.update!(briefing_error: 'x')

    assert_operator stale.reload.updated_at, :>, @now - 3600
    assert_equal :warn, card[:status]
  end

  test 'staleness ignores updated_at on a refreshed project' do
    stale = project('g/touched', generated_ago: 7 * 3600)
    stale.update!(updated_at: @now)

    assert_equal :warn, card[:status]
  end

  test 'the sample carries the refresh error' do
    project('g/broken', generated_ago: 7 * 3600, error: 'git clone (main) failed: fatal: x')

    assert_equal ['g/broken (7.0h: git clone (main) failed: fatal: x)'], card[:meta][:sample]
  end

  def seven_projects_six_stale
    project('g/fresh', generated_ago: 3600)
    6.times { |i| project("g/stale#{i}", generated_ago: (7 + i) * 3600, error: 'e' * 300) }
  end

  test 'counts: the detail counts the stale, the meta counts them all' do
    seven_projects_six_stale

    assert_match(/\A6 project briefing\(s\) /, card[:detail])
    assert_equal 7, card[:meta][:count]
    assert_equal 6 * 3600, card[:meta][:stale_after_seconds]
  end

  test 'counts: the sample stops at five, stalest first' do
    seven_projects_six_stale

    assert_equal 5, card[:meta][:sample].size
    assert_match %r{\Ag/stale5 \(12\.0h: }, card[:meta][:sample].first
  end

  test 'counts: a sampled error is cut at 120 characters' do
    seven_projects_six_stale

    excerpts = card[:meta][:sample].map { |entry| entry[/: (e+)\)\z/, 1].size }

    assert_equal [120] * 5, excerpts
  end

  # One failed run behind a fresh briefing is noise; the count still shows it.
  test 'a fresh briefing with an error stays ok and is counted as failing' do
    project('g/flaky', generated_ago: 3600, error: 'danger-claude failed (exit 1): boom')
    project('g/fine', generated_ago: 3600)

    assert_equal :ok, card[:status]
    assert_equal({ count: 2, stale_after_seconds: 6 * 3600, failing: 1 }, card[:meta])
  end

  # Recurring jobs do not run in a local env, so every briefing there is stale
  # by construction.
  test 'ok where the refresh is not scheduled, however old the briefing' do
    project('g/ancient', generated_ago: 2 * 86_400)

    check = card(poller_expected: false)

    assert_equal :ok, check[:status]
    assert_equal 'briefing refresh not scheduled here', check[:detail]
  end

  # In test `Rails.env.local?` is true, so the controller's bare
  # `HealthReport.new` would answer "not scheduled" and prove nothing: the
  # constructor is wrapped to force the production behaviour.
  test 'healthz still answers 200 with the warn in its body' do
    project('g/stale', generated_ago: 7 * 3600, created_ago: 30 * 86_400)
    real_new = Autodev::HealthReport.method(:new)
    forced = ->(**kwargs) { real_new.call(**kwargs, now: @now, poller_expected: true) }

    Autodev::HealthReport.stub(:new, forced) { get '/healthz/project_briefings' }

    assert_response :ok
    body = JSON.parse(response.body)

    assert_equal 'warn', body['status']
    assert_equal 'warn', body.dig('checks', 'project_briefings', 'status')
  end
end
