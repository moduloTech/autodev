# frozen_string_literal: true

module Web
  module Views
    # GET /issues/:id — sidebar + topbar + cards.
    # Same shell as the rest of the app; chat panel from screen-issue-detail.jsx
    # is deliberately out of scope.
    class IssueShow < Base # rubocop:disable Metrics/ClassLength
      def initialize(issue:, issue_model:, events:, kpis:, **)
        super(**)
        @issue = issue
        @issue_model = issue_model
        @events = events
        @kpis = kpis
      end

      def view_template # rubocop:disable Metrics/MethodLength
        with_layout(nav: false, shell: false) do
          div(class: 'app-shell') do
            render_sidebar
            main do
              render_topbar
              div(class: 'issue-content', style: 'flex: 1; overflow: auto; padding: 28px;') do
                render_status_band
                render_grid
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
          translator: ->(key, **vars) { t_web(key, **vars) }, admin: @current_user_admin
        )
      end

      def render_topbar # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
        render(Components::Topbar.new(
                 title: @issue[:issue_title].to_s,
                 breadcrumb: t_web(:web_issue_breadcrumb, project: @issue[:project_path], iid: @issue[:issue_iid])
               )) do
          if (url = gitlab_issue_url(@issue))
            render Components::Button.new(kind: :secondary, size: :md, href: url,
                                          icon: Components::Icon.new(name: 'external', size: 14)) do
              t_web(:web_issue_view_on_gitlab)
            end
          end
          if (url = gitlab_mr_url(@issue))
            render Components::Button.new(kind: :secondary, size: :md, href: url,
                                          icon: Components::Icon.new(name: 'git-mr', size: 14)) do
              t_web(:web_issue_view_mr)
            end
          end
        end
      end

      # Big status pill + secondary descriptors, just under the topbar.
      def render_status_band # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
        div(class: 'issue-status-band') do
          span(id: "status_#{@issue[:id]}", style: 'display: inline-flex;') do
            render status_pill(@issue[:status], size: :lg)
          end
          if @issue[:branch_name] && !@issue[:branch_name].empty?
            span(class: 'muted', style: 'display: inline-flex; align-items: center; gap: 6px;') do
              render Components::Icon.new(name: 'branch', size: 14)
              code { plain @issue[:branch_name] }
            end
          end
          span(class: 'muted', style: 'display: inline-flex; align-items: center; gap: 6px;') do
            render Components::Icon.new(name: 'clock', size: 14)
            plain relative_time(@issue[:created_at])
          end
        end
      end

      def render_grid # rubocop:disable Metrics/MethodLength
        div(class: 'issue-grid') do
          div(style: 'display: flex; flex-direction: column; gap: 22px;') do
            render_activity_card
            render_screenshots_card
            render_raw_card
          end
          div(style: 'display: flex; flex-direction: column; gap: 22px;') do
            render_metadata_card
            render_actions_card
          end
        end
      end

      # === Metadata =========================================================

      METADATA_ROWS = [
        [:web_col_branch,                ->(i, _h) { i[:branch_name] }, :code],
        [:web_issue_locale,              ->(i, h) { h.locale_label(i[:locale] || 'fr') }],
        [:web_issue_retry_count,         ->(i, _h) { i[:retry_count] }],
        [:web_issue_review_count,        ->(i, _h) { i[:review_count] }],
        [:web_issue_pipeline_retriggers, ->(i, _h) { i[:pipeline_retrigger_count] }],
        [:web_issue_started_at,          ->(i, _h) { i[:started_at] }],
        [:web_col_created_at,            ->(i, _h) { i[:created_at] }]
      ].freeze
      private_constant :METADATA_ROWS

      def render_metadata_card # rubocop:disable Metrics/MethodLength
        render(Components::Card.new(padding: 0)) do
          div(class: 'card-section-header') do
            h3(class: 'card-section-title') { t_web(:web_issue_metadata) }
          end
          div(class: 'kv-grid', style: 'padding: 14px 18px; gap: 10px;') do
            METADATA_ROWS.each { |key, getter, fmt| render_metadata_row(key, getter.call(@issue, self), fmt) }
            render_error_row(:web_col_error, @issue[:error_message]) if @issue[:error_message]
            if @issue[:post_completion_error]
              render_error_row(:web_issue_post_completion_error, @issue[:post_completion_error])
            end
          end
        end
      end

      def render_metadata_row(key, value, fmt = nil)
        div(class: 'kv-row') do
          span(class: 'kv-label') { t_web(key) }
          span(class: 'kv-value') do
            fmt == :code ? code { plain value.to_s } : plain(value.to_s)
          end
        end
      end

      def render_error_row(key, value)
        div do
          div(class: 'kv-label', style: 'margin-bottom: 4px;') { t_web(key) }
          pre(class: 'technical-pre') { value.to_s }
        end
      end

      # === Actions ==========================================================

      def render_actions_card
        render(Components::Card.new) do
          h3(class: 'sidecard-title') { t_web(:web_issue_actions) }
          div(style: 'display: flex; flex-direction: column; gap: 10px;') do
            render_reset_form
            render_transition_section
          end
        end
      end

      def render_reset_form
        form(method: 'post', action: "/issues/#{@issue[:id]}/reset",
             data: { confirm: t_web(:web_issue_confirm_reset) }) do
          csrf_input_tag
          render Components::Button.new(kind: :danger, size: :md, full: true, type: 'submit',
                                        icon: Components::Icon.new(name: 'refresh', size: 13)) do
            t_web(:web_issue_reset)
          end
        end
      end

      def render_transition_section
        events = permitted_events_for(@issue_model)
        if events.any?
          render_transition_form(events)
        else
          p(class: 'muted', style: 'font-size: 12px; margin: 0;') do
            plain "#{t_web(:web_issue_no_transitions)} "
            code { @issue[:status] }
            plain '.'
          end
        end
      end

      def render_transition_form(events)
        template = "#{t_web(:web_issue_confirm_transition_prefix)}$event#{t_web(:web_issue_confirm_transition_suffix)}"
        form(method: 'post', action: "/issues/#{@issue[:id]}/transition",
             data: { 'confirm-template' => template },
             style: 'display: flex; gap: 8px; align-items: center;') do
          csrf_input_tag
          select(name: 'event', style: 'flex: 1;') do
            events.each { |event| option(value: event.to_s) { event_label(event) } }
          end
          render Components::Button.new(size: :md, type: 'submit') { t_web(:web_issue_force_transition) }
        end
      end

      # === Activity =========================================================

      def render_activity_card
        render(Components::Card.new(padding: 0)) do
          div(class: 'card-section-header') do
            h3(class: 'card-section-title') { t_web(:web_issue_activity, count: @events.size) }
          end
          if @events.empty?
            div(class: 'empty-state') { p(class: 'muted') { t_web(:web_issue_no_activity) } }
          else
            render_activity_table
          end
        end
      end

      def render_activity_table # rubocop:disable Metrics/MethodLength
        table(class: 'activity-table') do
          thead do
            tr do
              %i[web_activity_col_date web_activity_col_kind web_activity_col_level web_activity_col_detail]
                .each { |k| th { t_web(k) } }
            end
          end
          tbody(id: "events_#{@issue[:id]}") do
            @events.each { |event| render_activity_row(event) }
          end
        end
      end

      def render_activity_row(event)
        tr do
          td(class: 'muted') { event[:created_at] }
          td { event_kind_label(event[:kind]) }
          td { event[:level] }
          td { format_event(event) }
        end
      end

      # === Screenshots ======================================================

      def render_screenshots_card # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
        screenshots = screenshot_files(@issue)
        return if screenshots.empty?

        render(Components::Card.new) do
          h3(class: 'sidecard-title') { t_web(:web_issue_screenshots, count: screenshots.size) }
          ul(style: 'margin: 0; padding-left: 20px; font-size: 12px;') do
            screenshots.each { |path| li { code { path } } }
          end
          p(class: 'muted', style: 'font-size: 11px; margin-top: 10px;') do
            plain "#{t_web(:web_issue_screenshots_dir)} "
            code { screenshot_dir_for(@issue) }
            plain '.'
          end
        end
      end

      # === Raw data =========================================================

      def render_raw_card
        render(Components::Card.new(padding: 0)) do
          details do
            summary(class: 'card-section-header', style: 'cursor: pointer; list-style: none;') do
              h3(class: 'card-section-title', style: 'display: inline;') { t_web(:web_issue_raw_data) }
            end
            pre(class: 'yaml-pre') { JSON.pretty_generate(@issue) }
          end
        end
      end
    end
  end
end
