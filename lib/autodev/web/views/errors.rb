# frozen_string_literal: true

module Web
  module Views
    # GET /errors — issues in error / needs_clarification / with post_completion_error.
    class Errors < Base
      def initialize(errored:, **)
        super(**)
        @errored = errored
      end

      def view_template
        with_layout do
          h1 { t_web(:web_errors_title) }
          if @errored.empty?
            p(class: 'muted') { t_web(:web_errors_none) }
          else
            render_table
          end
        end
      end

      private

      def render_table
        table do
          tr do
            %i[web_col_project web_col_iid web_col_status web_col_message]
              .each { |k| th { t_web(k) } }
            th { plain '' }
          end
          @errored.each { |row| render_row(row) }
        end
      end

      def render_row(row) # rubocop:disable Metrics/AbcSize
        tr do
          td { a(href: "/projects/#{project_slug(row[:project_path])}") { row[:project_path] } }
          td { a(href: "/issues/#{row[:id]}") { plain "##{row[:issue_iid]}" } }
          td { render status_pill(row[:status]) }
          td { render_message(row) }
          td { render_reset_form(row) }
        end
      end

      def render_message(row)
        msg = row[:error_message] || row[:post_completion_error]
        return unless msg

        pre { msg.to_s[0, 400] }
      end

      def render_reset_form(row)
        form(method: 'post', action: "/issues/#{row[:id]}/reset",
             data: { confirm: t_web(:web_errors_confirm_reset, iid: row[:issue_iid]) }) do
          button(type: 'submit') { t_web(:web_issue_reset) }
        end
      end
    end
  end
end
