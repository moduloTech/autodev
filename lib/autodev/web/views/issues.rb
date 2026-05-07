# frozen_string_literal: true

module Web
  module Views
    # GET /issues — sidebar + topbar + tab bar + dense table (desktop) /
    # stacked cards (mobile). Mirrors design_handoff_autodev/screen-issues.jsx.
    class Issues < Base # rubocop:disable Metrics/ClassLength
      TABS = [
        { id: 'active',  label_key: :web_tab_active,  count_key: :active },
        { id: 'errors',  label_key: :web_tab_errors,  count_key: :errors,  tone: :err },
        { id: 'waiting', label_key: :web_tab_waiting, count_key: :waiting, tone: :warn },
        { id: 'done',    label_key: :web_tab_done,    count_key: :done },
        { id: 'all',     label_key: :web_tab_all,     count_key: :all }
      ].freeze
      private_constant :TABS

      # rubocop:disable Metrics/ParameterLists
      def initialize(issues:, total:, total_pages:, page:, per_page:, filters:, # rubocop:disable Metrics/ParameterLists
                     tab:, tab_counts:, kpis:, **)
        super(**)
        @issues = issues
        @total = total
        @total_pages = total_pages
        @page = page
        @per_page = per_page
        @filters = filters
        @tab = tab
        @tab_counts = tab_counts
        @kpis = kpis
      end
      # rubocop:enable Metrics/ParameterLists

      def view_template # rubocop:disable Metrics/MethodLength
        with_layout(nav: false, shell: false) do
          div(class: 'app-shell') do
            render_sidebar
            main do
              render_topbar
              render_filter_bar
              div(class: 'issues-content', style: 'flex: 1; overflow: auto;') do
                if @issues.empty?
                  render_empty
                else
                  render_table
                  render_cards
                  render_pager if @total_pages > 1
                end
              end
            end
          end
        end
      end

      private

      def render_sidebar
        render Components::Sidebar.new(
          active: 'issues', locale: web_locale, request_path: @request_path,
          counts: { issues: @kpis[:active], errors: @kpis[:errors], chat: 0 },
          translator: ->(key, **vars) { t_web(key, **vars) }
        )
      end

      def render_topbar
        render(Components::Topbar.new(
                 title: t_web(:web_issues_title),
                 subtitle: t_web(:web_issues_subtitle)
               )) do
          span(class: 'coming-soon', title: t_web(:web_coming_soon_tooltip)) do
            render Components::Button.new(kind: :primary, size: :md,
                                          icon: Components::Icon.new(name: 'plus', size: 14),
                                          href: '#') { t_web(:web_dashboard_new_request) }
          end
        end
      end

      def render_filter_bar
        div(class: 'filter-bar') do
          div(class: 'filter-tabs') { TABS.each { |tab| render_tab(tab) } }
          render_search_form
        end
      end

      def render_tab(tab) # rubocop:disable Metrics/AbcSize
        is_active = @tab == tab[:id]
        count = @tab_counts[tab[:count_key]] || 0
        a(href: tab_href(tab[:id]), class: is_active ? 'tab tab-active' : 'tab',
          style: tab_style(is_active)) do
          plain t_web(tab[:label_key])
          plain ' '
          span(class: tab_count_classes(tab[:tone], is_active),
               style: tab_count_style(tab[:tone], is_active)) { plain count.to_s }
        end
      end

      def tab_href(tab_id)
        params = { tab: tab_id }
        params[:q] = @filters[:q] if @filters[:q] && !@filters[:q].empty?
        "/issues?#{URI.encode_www_form(params)}"
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

      def tab_count_classes(_tone, _active)
        'tab-count'
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

      def render_search_form # rubocop:disable Metrics/MethodLength
        form(method: 'get', action: '/issues', class: 'filter-search-form') do
          input(type: 'hidden', name: 'tab', value: @tab)
          div(class: 'search-input') do
            render Components::Icon.new(name: 'search', size: 14, color: 'var(--text-muted)')
            input(type: 'text', name: 'q', value: @filters[:q].to_s,
                  placeholder: t_web(:web_issues_search_placeholder),
                  class: 'search-field')
          end
          span(class: 'coming-soon', title: t_web(:web_coming_soon_tooltip)) do
            render Components::Button.new(size: :md,
                                          icon: Components::Icon.new(name: 'filter', size: 14),
                                          href: '#') { t_web(:web_issues_filter) }
          end
        end
      end

      def render_empty
        div(class: 'empty-state') { p(class: 'muted') { t_web(:web_issues_no_results) } }
      end

      def render_table
        div(class: 'issues-table') do
          render_table_header
          @issues.each_with_index { |row, idx| render_table_row(row, idx == @issues.length - 1) }
        end
      end

      def render_table_header
        div(class: 'issues-table-header') do
          span { '#' }
          span { t_web(:web_issues_col_title) }
          span { t_web(:web_issues_col_status) }
          span { t_web(:web_issues_col_activity) }
        end
      end

      def render_table_row(row, last)
        a(class: 'issues-row', style: row_style(last), href: "/issues/#{row[:id]}") do
          span(class: 'iid') { plain "##{row[:issue_iid]}" }
          div(class: 'title-cell') do
            div(class: 'title') { row[:issue_title] }
            div(class: 'meta') { row[:project_path] }
          end
          render status_pill(row[:status], size: :sm)
          span(class: 'activity-cell') { relative_time(row[:created_at]) }
        end
      end

      def row_style(last)
        border = last ? 'none' : '1px solid var(--divider)'
        "border-bottom: #{border};"
      end

      # Mobile-only stacked cards. Hidden on desktop via CSS.
      def render_cards
        div(class: 'issues-cards') do
          @issues.each { |row| render_card(row) }
        end
      end

      def render_card(row)
        a(class: 'issue-card', href: "/issues/#{row[:id]}") do
          div(class: 'issue-card-header') do
            span(class: 'iid-meta') { plain "##{row[:issue_iid]} · #{row[:project_path]}" }
            render status_pill(row[:status], size: :sm)
          end
          div(class: 'issue-card-title') { row[:issue_title] }
          div(class: 'issue-card-footer') do
            span(class: 'muted') { relative_time(row[:created_at]) }
          end
        end
      end

      def render_pager
        div(class: 'issues-pager') do
          a(href: page_link(@page - 1)) { t_web(:web_issues_prev) } if @page > 1
          span(class: 'muted') do
            plain " #{t_web(:web_issues_page_indicator, page: @page, total: @total_pages)} "
          end
          a(href: page_link(@page + 1)) { t_web(:web_issues_next) } if @page < @total_pages
        end
      end

      def page_link(page)
        params = { tab: @tab, q: @filters[:q], page: page, per_page: @per_page }
                 .reject { |_, v| v.nil? || v == '' }
        "?#{URI.encode_www_form(params)}"
      end
    end
  end
end
