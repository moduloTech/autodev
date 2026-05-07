# frozen_string_literal: true

module Web
  module Views
    # GET /list/:status — single-status browse, capped at 500 rows.
    class List < Base
      LIMIT = 500

      def initialize(status:, issues:, **)
        super(**)
        @status = status
        @issues = issues
      end

      def view_template
        with_layout do
          render_header
          render_count
          if @issues.empty?
            p(class: 'muted') { t_web(:web_list_none) }
          else
            render_table
          end
          p { a(href: '/') { t_web(:web_list_back) } }
        end
      end

      private

      def render_header
        h1 do
          plain t_web(:web_list_title)
          span(class: status_class(@status)) { @status }
          plain ' '
          span(class: 'muted') { status_label(@status) }
        end
      end

      def render_count
        key = @issues.size == LIMIT ? :web_list_count_capped : :web_list_count
        p(class: 'muted') { t_web(key, count: @issues.size) }
      end

      def render_table
        table do
          tr do
            %i[web_col_project web_col_iid web_col_title web_col_branch web_col_mr]
              .each { |k| th { t_web(k) } }
          end
          @issues.each { |row| render_row(row) }
        end
      end

      def render_row(row) # rubocop:disable Metrics/AbcSize
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
    end
  end
end
