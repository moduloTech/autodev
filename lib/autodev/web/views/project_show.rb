# frozen_string_literal: true

module Web
  module Views
    # GET /projects/:slug — config app: + recent issues for one project.
    class ProjectShow < Base
      def initialize(project_path:, project_config:, project_issues:, **)
        super(**)
        @project_path = project_path
        @project_config = project_config
        @project_issues = project_issues
      end

      def view_template
        with_layout do
          h1 { t_web(:web_project_title, path: @project_path) }
          render_config
          render_issues
        end
      end

      private

      def render_config
        h2 do
          # web_project_config carries inline <code> markup; mark it safe.
          raw safe(t_web(:web_project_config))
        end
        if @project_config.empty?
          p(class: 'muted') { t_web(:web_project_no_config) }
        else
          pre { YAML.dump(@project_config) }
        end
      end

      def render_issues
        h2 { t_web(:web_project_recent, count: @project_issues.size) }
        if @project_issues.empty?
          p(class: 'muted') { t_web(:web_project_no_issues) }
        else
          render_issues_table
        end
      end

      def render_issues_table
        table do
          tr do
            %i[web_col_iid web_col_status web_col_title web_col_branch web_col_mr]
              .each { |k| th { t_web(k) } }
          end
          @project_issues.each { |row| render_row(row) }
        end
      end

      def render_row(row)
        tr do
          td { a(href: "/issues/#{row[:id]}") { plain "##{row[:issue_iid]}" } }
          td { render status_pill(row[:status]) }
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
