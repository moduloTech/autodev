# frozen_string_literal: true

# Unauthenticated health endpoints for external probes (Datadog, BetterStack).
#
# Like AssetsController, this opts out of the global SSO gate — an external
# monitor can't complete a Microsoft 365 handshake. The payload is deliberately
# non-sensitive (no secrets, no filesystem paths). An optional bearer token
# (config `monitoring.token`) gates access; nil = open, matching the
# 127.0.0.1 / NetBird trust model the rest of the dashboard relies on.
#
# Routes (see config/routes.rb):
#   GET /healthz(.json)   → full HealthReport, HTTP 200 if ok else 503
#   GET /healthz/:check   → one component (poller/workers/queue/…), same codes
# `/up` is wired straight to Rails' own health controller for pure liveness.
class MonitoringController < ApplicationController
  skip_forgery_protection
  skip_before_action :authenticate_user!, raise: false
  before_action :require_monitoring_token

  def show
    render_report(Autodev::HealthReport.new.call)
  end

  def component
    render_report(Autodev::HealthReport.new.check(params[:check]))
  rescue ArgumentError => e
    render json: { error: e.message }, status: :not_found
  end

  private

  # 200 when healthy, 503 otherwise — external probes alert on the status code,
  # the JSON body carries the per-component breakdown for debugging.
  def render_report(report)
    code = report[:status] == :ok ? :ok : :service_unavailable
    render json: report, status: code
  end

  def require_monitoring_token
    expected = ::Web.config&.dig('monitoring', 'token')
    return if expected.blank?
    return if ActiveSupport::SecurityUtils.secure_compare(provided_token.to_s, expected.to_s)

    render json: { error: 'unauthorized' }, status: :unauthorized
  end

  def provided_token
    request.headers['Authorization'].to_s[/\ABearer\s+(.+)\z/, 1] || params[:token]
  end
end
