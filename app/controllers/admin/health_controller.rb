# frozen_string_literal: true

module Admin
  # GET /admin/health — admin-gated system health dashboard. Renders the same
  # Autodev::HealthReport that powers the unauthenticated /healthz endpoints,
  # but as a human page inside the dashboard chrome. Passive: no live probes.
  class HealthController < AdminApplicationController
    include ::Web::Helpers

    def show
      report = ::Autodev::HealthReport.new.call
      render html: ::Web::Views::Admin::Health.new(report: report, **view_kwargs).call.html_safe, layout: false
    end
  end
end
