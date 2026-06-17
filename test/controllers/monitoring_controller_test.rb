# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'

# /healthz monitoring endpoints. These must be reachable WITHOUT Microsoft 365
# SSO (external probes can't authenticate), map health status to HTTP code
# (200 ok / 503 otherwise), and honour the optional monitoring.token gate.
class MonitoringControllerTest < ActionDispatch::IntegrationTest
  OK_REPORT = { status: :ok, generated_at: '2026-06-17T00:00:00Z',
                checks: { poller: { status: :ok, detail: 'fresh', meta: {} } } }.freeze
  DOWN_REPORT = { status: :down, generated_at: '2026-06-17T00:00:00Z',
                  checks: { poller: { status: :down, detail: 'stale', meta: {} } } }.freeze
  WARN_REPORT = { status: :warn, generated_at: '2026-06-17T00:00:00Z',
                  checks: { issues_error: { status: :warn, detail: '6 in error', meta: {} } } }.freeze

  def with_report(report, &)
    fake = Object.new
    fake.define_singleton_method(:call) { report }
    fake.define_singleton_method(:check) { |_name| report }
    # Wrap in a lambda: Minitest's stub *invokes* a value that responds to
    # :call, and our fake does — so hand it a callable that returns the fake.
    Autodev::HealthReport.stub(:new, ->(*, **) { fake }, &)
  end

  def with_token(token)
    previous = ::Web.config
    ::Web.config = { 'monitoring' => { 'token' => token } }
    yield
  ensure
    ::Web.config = previous
  end

  test 'healthz returns 200 + JSON body when healthy' do
    with_report(OK_REPORT) { get '/healthz' }

    assert_response :ok
    assert_equal 'ok', JSON.parse(response.body)['status']
  end

  test 'healthz returns 503 only on a real outage (down)' do
    with_report(DOWN_REPORT) { get '/healthz' }

    assert_response :service_unavailable
    assert_equal 'down', JSON.parse(response.body)['status']
  end

  test 'healthz returns 200 on warn (degraded but up — no uptime page)' do
    with_report(WARN_REPORT) { get '/healthz' }

    assert_response :ok
    assert_equal 'warn', JSON.parse(response.body)['status']
  end

  test 'healthz is reachable anonymously (not redirected to SSO)' do
    with_report(OK_REPORT) { get '/healthz' }

    assert_response :ok
    refute_equal 302, status
  end

  test 'component endpoint returns a single check' do
    with_report(OK_REPORT) { get '/healthz/poller' }

    assert_response :ok
    assert JSON.parse(response.body)['checks'].key?('poller')
  end

  test 'token gate rejects when configured token is missing' do
    with_token('s3cret') { with_report(OK_REPORT) { get '/healthz' } }

    assert_response :unauthorized
  end

  test 'token gate accepts a correct bearer token' do
    with_token('s3cret') do
      with_report(OK_REPORT) { get '/healthz', headers: { 'Authorization' => 'Bearer s3cret' } }
    end

    assert_response :ok
  end

  test 'token gate accepts the token as a query param' do
    with_token('s3cret') { with_report(OK_REPORT) { get '/healthz', params: { token: 's3cret' } } }

    assert_response :ok
  end
end
