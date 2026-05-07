# frozen_string_literal: true

module Web
  module Views
    module Components
      # Page header bar: title, optional subtitle, optional breadcrumb,
      # optional menu-button (mobile), and an actions slot rendered on
      # the right. Mirrors primitives.jsx::Topbar.
      class Topbar < Phlex::HTML
        def initialize(title:, subtitle: nil, breadcrumb: nil, compact: false) # rubocop:disable Lint/MissingSuper
          @title = title
          @subtitle = subtitle
          @breadcrumb = breadcrumb
          @compact = compact
        end

        def view_template(&)
          div(class: 'topbar', style: bar_style) do
            div(style: 'flex: 1; min-width: 0;') do
              render_breadcrumb if @breadcrumb
              h1(style: title_style) { @title }
              render_subtitle if @subtitle && !@compact
            end
            div(style: 'display: flex; gap: 8px; align-items: center;', &) if block_given?
          end
        end

        private

        def bar_style
          padding = @compact ? '14px 16px' : '20px 32px'
          gap = @compact ? 12 : 24
          "padding: #{padding}; border-bottom: 1px solid var(--border); " \
            "background: var(--paper); display: flex; align-items: center; gap: #{gap}px; " \
            'flex: 0 0 auto;'
        end

        def title_style
          font_size = @compact ? 17 : 22
          "margin: 0; font-size: #{font_size}px; font-weight: 600; letter-spacing: -0.3px; " \
            'color: var(--text-strong); overflow: hidden; text-overflow: ellipsis; white-space: nowrap;'
        end

        def render_breadcrumb
          div(style: 'font-size: 12px; color: var(--text-muted); margin-bottom: 4px; ' \
                     'overflow: hidden; text-overflow: ellipsis; white-space: nowrap;') { @breadcrumb }
        end

        def render_subtitle
          div(style: 'font-size: 13px; color: var(--text-muted); margin-top: 4px;') { @subtitle }
        end
      end
    end
  end
end
