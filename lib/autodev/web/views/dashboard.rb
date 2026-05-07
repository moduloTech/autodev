# frozen_string_literal: true

module Web
  module Views
    # GET / — counters per status, active issues grouped by status, project breakdown.
    class Dashboard < Base # rubocop:disable Metrics/ClassLength
      def initialize(counts:, active:, grouped:, by_project:, **)
        super(**)
        @counts = counts
        @active = active
        @grouped = grouped
        @by_project = by_project
      end

      def view_template
        with_layout do
          h1 { t_web(:web_dashboard_title) }
          render_counters
          render_active
          render_by_project
        end
      end

      private

      def render_counters # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
        h2 { t_web(:web_dashboard_counters) }
        table do
          tr do
            th { t_web(:web_col_status) }
            th { t_web(:web_col_total) }
          end
          ::Dashboard::STATUS_COLORS.each_key do |status|
            count = @counts[status] || 0
            next if count.zero?

            tr do
              td { render_status_link(status, count, label: true) }
              td { a(href: "/list/#{status}") { plain count } }
            end
          end
        end
      end

      def render_status_link(status, _count, label:)
        a(href: "/list/#{status}") do
          span(class: status_class(status)) { status }
          plain ' '
          span(class: 'muted') { status_label(status) } if label
        end
      end

      def render_active
        h2 { t_web(:web_dashboard_active_issues, count: @active.size) }
        if @active.empty?
          p(class: 'muted') { t_web(:web_dashboard_no_active) }
        else
          @grouped.each { |status, rows| render_active_group(status, rows) }
        end
      end

      def render_active_group(status, rows) # rubocop:disable Metrics/MethodLength
        h3 do
          span(class: status_class(status)) { status }
          plain ' '
          span(class: 'muted') { status_label(status) }
          plain " (#{rows.size})"
        end
        table do
          tr do
            %i[web_col_project web_col_iid web_col_title web_col_branch web_col_mr]
              .each { |k| th { t_web(k) } }
          end
          rows.each { |row| render_active_row(row) }
        end
      end

      def render_active_row(row) # rubocop:disable Metrics/AbcSize
        tr do
          td { a(href: "/projects/#{project_slug(row[:project_path])}") { row[:project_path] } }
          td { a(href: "/issues/#{row[:id]}") { plain "##{row[:issue_iid]}" } }
          td { row[:issue_title] }
          td { code { row[:branch_name] } }
          td { render_mr_link(row) }
        end
      end

      def render_mr_link(row)
        return unless row[:mr_url] && !row[:mr_url].empty?

        a(href: row[:mr_url], target: '_blank', rel: 'noopener') { plain "!#{row[:mr_iid]}" }
      end

      def render_by_project
        h2 { t_web(:web_dashboard_by_project) }
        if @by_project.empty?
          p(class: 'muted') { t_web(:web_dashboard_no_project) }
        else
          render_by_project_table
        end
      end

      def render_by_project_table # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
        table do
          tr do
            %i[web_col_project web_col_total web_col_active web_col_done web_col_error]
              .each { |k| th { t_web(k) } }
          end
          @by_project.each do |stats|
            tr do
              td { a(href: "/projects/#{project_slug(stats[:path])}") { stats[:path] } }
              td { plain stats[:total] }
              td { plain stats[:active] }
              td { plain stats[:done] }
              td { plain stats[:error] }
            end
          end
        end
      end
    end
  end
end
