# frozen_string_literal: true

module Web
  module Views
    module Concerns
      # Pill-style filter tabs shared by the /issues and /autospec_drafts list
      # views, so both render the same markup (`.filter-bar` / `.filter-tabs` /
      # `.tab` / `.tab-count`). Pure presentation: the caller supplies the
      # label, count, active state, href, and optional tone (:err / :warn for a
      # coloured count badge).
      module FilterTabs
        def render_filter_tab(label:, count:, active:, href:, tone: nil)
          a(href: href, class: active ? 'tab tab-active' : 'tab', style: tab_style(active)) do
            plain label
            plain ' '
            span(class: 'tab-count', style: tab_count_style(tone, active)) { plain count.to_s }
          end
        end

        def tab_style(active)
          bg = active ? 'var(--paper-2)' : 'transparent'
          color = active ? 'var(--text-strong)' : 'var(--text-muted)'
          border = active ? '1px solid var(--border)' : '1px solid transparent'
          'display: inline-flex; align-items: center; gap: 6px; padding: 6px 12px; ' \
            'border-radius: var(--r-pill); font-size: 13px; font-weight: 500; ' \
            'white-space: nowrap; text-decoration: none; ' \
            "background: #{bg}; color: #{color}; border: #{border};"
        end

        def tab_count_style(tone, active) # rubocop:disable Metrics/MethodLength
          bg = case tone
               when :err then 'var(--err-bg)'
               when :warn then 'var(--warn-bg)'
               else (active ? 'var(--paper)' : 'var(--paper-2)')
               end
          color = case tone
                  when :err then 'var(--err-fg)'
                  when :warn then 'var(--warn-fg)'
                  else 'var(--text-muted)'
                  end
          border = %i[err warn].include?(tone) ? 'none' : '1px solid var(--border)'
          'font-size: 11px; padding: 0 6px; border-radius: var(--r-pill); ' \
            "background: #{bg}; color: #{color}; border: #{border};"
        end
      end
    end
  end
end
