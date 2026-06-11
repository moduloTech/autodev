# frozen_string_literal: true

module Web
  module Views
    module Components
      # Big-number stat card. Mirrors screen-dashboard.jsx::KPI.
      class Kpi < Phlex::HTML
        TONES = {
          working: { bg: 'var(--work-bg)', fg: 'var(--work-fg)' },
          ok: { bg: 'var(--ok-bg)', fg: 'var(--ok-fg)' },
          warn: { bg: 'var(--warn-bg)', fg: 'var(--warn-fg)' },
          err: { bg: 'var(--err-bg)', fg: 'var(--err-fg)' }
        }.freeze

        # rubocop:disable Metrics/ParameterLists
        def initialize(label:, value:, tone:, icon_name:, hint: nil, compact: false, href: nil) # rubocop:disable Lint/MissingSuper
          @label = label
          @value = value
          @tone = TONES[tone] || TONES[:working]
          @icon_name = icon_name
          @hint = hint
          @compact = compact
          @href = href
        end
        # rubocop:enable Metrics/ParameterLists

        def view_template
          if @href
            a(href: @href, class: 'kpi-link', style: 'text-decoration: none; color: inherit; display: block;') do
              render_card
            end
          else
            render_card
          end
        end

        private

        def render_card
          render Card.new(padding: @compact ? 14 : 18,
                          extra_style: "display: flex; flex-direction: column; gap: #{@compact ? 6 : 10}px;") do
            render_top_row
            render_value
            render_hint if @hint && !@compact
          end
        end

        def render_top_row
          div(style: 'display: flex; align-items: center; justify-content: space-between;') do
            span(style: 'font-size: 11px; color: var(--text-muted); font-weight: 500; line-height: 1.3;') { @label }
            span(style: badge_style) { render Icon.new(name: @icon_name, size: 13) }
          end
        end

        def badge_style
          'width: 26px; height: 26px; border-radius: 8px; ' \
            "background: #{@tone[:bg]}; color: #{@tone[:fg]}; " \
            'display: inline-flex; align-items: center; justify-content: center;'
        end

        def render_value
          size = @compact ? 24 : 30
          div(style: "font-size: #{size}px; font-weight: 600; letter-spacing: -1px; " \
                     'color: var(--text-strong); line-height: 1; font-feature-settings: "tnum";') do
            plain @value.to_s
          end
        end

        def render_hint
          div(style: 'font-size: 11px; color: var(--text-muted);') { @hint }
        end
      end
    end
  end
end
