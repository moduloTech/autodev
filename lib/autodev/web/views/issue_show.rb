# frozen_string_literal: true

module Web
  module Views
    # GET /issues/:id — full detail page for a single tracked issue.
    class IssueShow < Base # rubocop:disable Metrics/ClassLength
      def initialize(issue:, issue_model:, events:, **)
        super(**)
        @issue = issue
        @issue_model = issue_model
        @events = events
      end

      def view_template
        with_layout do
          render_header
          render_links
          render_metadata
          render_actions
          render_activity
          render_screenshots
          render_raw_data
        end
      end

      def render_header
        h1 { t_web(:web_issue_title, iid: @issue[:issue_iid], project: @issue[:project_path]) }
        p do
          # The id wrapper is the Turbo Stream target updated on transitions.
          span(id: "status_#{@issue[:id]}", style: 'display: inline-flex') do
            render status_pill(@issue[:status])
          end
        end
        p { @issue[:issue_title] }
      end

      def render_links
        h2 { t_web(:web_issue_links) }
        ul do
          if (url = gitlab_issue_url(@issue))
            li { a(href: url, target: '_blank', rel: 'noopener') { t_web(:web_issue_link_gitlab) } }
          end
          if (url = gitlab_mr_url(@issue))
            li { a(href: url, target: '_blank', rel: 'noopener') { t_web(:web_issue_link_mr, iid: @issue[:mr_iid]) } }
          end
        end
      end

      METADATA_ROWS = [
        [:web_col_branch,             ->(i) { i[:branch_name] }, :code],
        [:web_issue_locale,           ->(i) { i[:locale] || 'fr' }],
        [:web_issue_retry_count,      ->(i) { i[:retry_count] }],
        [:web_issue_review_count,     ->(i) { i[:review_count] }],
        [:web_issue_pipeline_retriggers, ->(i) { i[:pipeline_retrigger_count] }],
        [:web_issue_started_at,       ->(i) { i[:started_at] }],
        [:web_col_created_at,         ->(i) { i[:created_at] }]
      ].freeze

      def render_metadata
        h2 { t_web(:web_issue_metadata) }
        table do
          METADATA_ROWS.each { |key, getter, fmt| render_metadata_row(key, getter.call(@issue), fmt) }
          render_error_row(:web_col_error, @issue[:error_message]) if @issue[:error_message]
          if @issue[:post_completion_error]
            render_error_row(:web_issue_post_completion_error,
                             @issue[:post_completion_error])
          end
        end
      end

      def render_metadata_row(key, value, fmt = nil)
        tr do
          td { t_web(key) }
          td do
            fmt == :code ? code { plain value.to_s } : plain(value.to_s)
          end
        end
      end

      def render_error_row(key, value)
        tr do
          td { t_web(key) }
          td { pre { value.to_s } }
        end
      end

      def render_actions # rubocop:disable Metrics/MethodLength
        h2 { t_web(:web_issue_actions) }
        render_reset_form
        events = permitted_events_for(@issue_model)
        if events.any?
          render_transition_form(events)
        else
          p(class: 'muted') do
            plain "#{t_web(:web_issue_no_transitions)} "
            code { @issue[:status] }
            plain '.'
          end
        end
      end

      def render_reset_form
        form(method: 'post', action: "/issues/#{@issue[:id]}/reset",
             style: 'display: inline',
             data: { confirm: t_web(:web_issue_confirm_reset) }) do
          button(type: 'submit') { t_web(:web_issue_reset) }
        end
      end

      def render_transition_form(events)
        template = "#{t_web(:web_issue_confirm_transition_prefix)}$event#{t_web(:web_issue_confirm_transition_suffix)}"
        form(method: 'post', action: "/issues/#{@issue[:id]}/transition",
             style: 'display: inline',
             data: { 'confirm-template' => template }) do
          select(name: 'event') { events.each { |event| option(value: event.to_s) { event.to_s } } }
          plain ' '
          button(type: 'submit') { t_web(:web_issue_force_transition) }
        end
      end

      def render_activity
        h2 { t_web(:web_issue_activity, count: @events.size) }
        if @events.empty?
          p(class: 'muted') { t_web(:web_issue_no_activity) }
        else
          render_activity_table
        end
      end

      def render_activity_table
        table do
          thead do
            tr do
              %i[web_activity_col_date web_activity_col_kind web_activity_col_level web_activity_col_detail]
                .each { |k| th { t_web(k) } }
            end
          end
          tbody(id: "events_#{@issue[:id]}") { @events.each { |event| render_activity_row(event) } }
        end
      end

      def render_activity_row(event)
        tr do
          td(class: 'muted') { event[:created_at] }
          td { code { event[:kind] } }
          td { event[:level] }
          td { format_event(event) }
        end
      end

      def render_screenshots
        screenshots = screenshot_files(@issue)
        return if screenshots.empty?

        h2 { t_web(:web_issue_screenshots, count: screenshots.size) }
        ul { screenshots.each { |path| li { code { path } } } }
        p(class: 'muted') do
          plain "#{t_web(:web_issue_screenshots_dir)} "
          code { screenshot_dir_for(@issue) }
          plain '.'
        end
      end

      def render_raw_data
        h2 { t_web(:web_issue_raw_data) }
        details do
          summary { 'JSON' }
          pre { JSON.pretty_generate(@issue) }
        end
      end
    end
  end
end
