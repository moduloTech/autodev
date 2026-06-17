# frozen_string_literal: true

module Web
  module Views
    module Admin
      # GET /admin/health — system health snapshot (Autodev::HealthReport) shown
      # as status cards. Passive read; the same data is served as JSON at
      # /healthz for external probes.
      class Health < Base
        # status => [background var, foreground var, dot var]
        TONES = {
          ok: %w[--ok-bg --ok-fg --ok-500],
          warn: %w[--warn-bg --warn-fg --warn-500],
          down: %w[--err-bg --err-fg --err-500]
        }.freeze
        STATUS_LABEL = { ok: :web_admin_health_status_ok, warn: :web_admin_health_status_warn,
                         down: :web_admin_health_status_down }.freeze
        PILL_BASE = 'display: inline-flex; align-items: center; gap: 5px; padding: 2px 8px; ' \
                    'font-size: 11px; font-weight: 500; line-height: 1.4; white-space: nowrap; ' \
                    'border-radius: var(--r-pill);'
        DOT = 'width: 5px; height: 5px; border-radius: 50%; flex: 0 0 auto;'
        STRONG_LABEL = 'font-size: 13px; font-weight: 600; color: var(--text-strong);'
        SUBTLE_RIGHT = 'margin-left: auto; font-size: 11px; color: var(--text-subtle);'
        private_constant :TONES, :STATUS_LABEL, :PILL_BASE, :DOT, :STRONG_LABEL, :SUBTLE_RIGHT

        def initialize(report:, **)
          super(**)
          @report = report
        end

        def view_template
          with_layout(nav: false, shell: false) do
            div(class: 'app-shell') do
              render_sidebar
              main { render_main }
            end
          end
        end

        private

        def render_main
          render_topbar
          div(class: 'admin-content', style: 'flex: 1; overflow: auto; display: flex; ' \
                                             'flex-direction: column; gap: 12px;') do
            render_overall
            render_cards
          end
        end

        def render_sidebar
          render Components::Sidebar.new(
            active: 'admin_health', locale: web_locale, request_path: @request_path,
            counts: {}, translator: ->(key, **vars) { t_web(key, **vars) }, admin: @current_user_admin,
            current_user_email: @current_user_email, csrf_token: @csrf_token
          )
        end

        def render_topbar
          render Components::Topbar.new(
            title: t_web(:web_admin_health_title),
            subtitle: t_web(:web_admin_health_subtitle),
            breadcrumb: t_web(:web_admin_health_breadcrumb)
          ) do
            a(href: '/admin/jobs', class: 'btn-secondary') { t_web(:web_admin_health_view_jobs) }
            a(href: '/healthz.json', class: 'btn-secondary') { t_web(:web_admin_health_view_json) }
          end
        end

        def render_overall
          render(Components::Card.new) do
            div(style: 'display: flex; align-items: center; gap: 12px;') do
              span(style: STRONG_LABEL) { plain t_web(:web_admin_health_overall) }
              status_pill(@report[:status])
              span(style: SUBTLE_RIGHT) { plain @report[:generated_at] }
            end
          end
        end

        def render_cards
          div(style: 'display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); ' \
                     'gap: 12px;') do
            @report[:checks].each { |name, check| render_check_card(name, check) }
          end
        end

        def render_check_card(name, check)
          render(Components::Card.new) do
            div(style: 'display: flex; align-items: center; gap: 8px; margin-bottom: 8px;') do
              span(style: STRONG_LABEL) { plain t_web(:"web_admin_health_check_#{name}") }
              span(style: 'margin-left: auto;') { status_pill(check[:status]) }
            end
            render_meta(check[:meta])
          end
        end

        def render_meta(meta)
          return if meta.blank?

          div(style: 'display: flex; flex-wrap: wrap; gap: 6px;') do
            meta.each do |key, value|
              span(style: 'font-size: 11px; color: var(--text-muted); border: 1px solid var(--border); ' \
                          'padding: 1px 6px; border-radius: 4px;') do
                plain "#{key}: #{value}"
              end
            end
          end
        end

        def status_pill(status)
          bg, fg, dot = TONES.fetch(status.to_sym, TONES[:warn])
          span(style: "#{PILL_BASE} background: var(#{bg}); color: var(#{fg});") do
            span(style: "#{DOT} background: var(#{dot});")
            plain t_web(STATUS_LABEL.fetch(status.to_sym, :web_admin_health_status_warn))
          end
        end
      end
    end
  end
end
