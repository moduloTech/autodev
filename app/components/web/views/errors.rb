# frozen_string_literal: true

module Web
  module Views
    # GET /errors — sidebar + topbar + warning banner + cards.
    # Mirrors design/screen-errors.jsx.
    class Errors < Base # rubocop:disable Metrics/ClassLength
      def initialize(errored:, kpis:, **)
        super(**)
        @errored = errored
        @kpis = kpis
      end

      def view_template # rubocop:disable Metrics/MethodLength
        with_layout(nav: false, shell: false) do
          div(class: 'app-shell') do
            render_sidebar
            main do
              render_topbar
              div(class: 'errors-content', style: 'flex: 1; overflow: auto;') do
                if @errored.empty?
                  render_empty
                else
                  render_banner
                  render_cards
                end
              end
            end
          end
        end
      end

      private

      def render_sidebar
        render Components::Sidebar.new(
          active: 'errors', locale: web_locale, request_path: @request_path,
          counts: { issues: @kpis[:active], errors: @kpis[:errors], chat: 0 },
          translator: ->(key, **vars) { t_web(key, **vars) }, admin: @current_user_admin,
          current_user_email: @current_user_email, csrf_token: @csrf_token
        )
      end

      def render_topbar
        render Components::Topbar.new(
          title: t_web(:web_errors_title),
          subtitle: t_web(:web_errors_subtitle)
        )
      end

      def render_empty
        div(class: 'empty-state') { p(class: 'muted') { t_web(:web_errors_none) } }
      end

      def render_banner
        div(class: 'errors-banner') do
          render Components::Icon.new(name: 'alert-tri', size: 20)
          div(style: 'flex: 1; font-size: 13px; line-height: 1.5;') do
            strong { plain banner_title }
            plain ' '
            plain t_web(:web_errors_banner_body)
          end
        end
      end

      def banner_title
        if @errored.size == 1
          t_web(:web_errors_banner_one)
        else
          t_web(:web_errors_banner_many, count: @errored.size)
        end
      end

      def render_cards
        div(class: 'errors-cards') do
          @errored.each { |row| render_error_card(row) }
        end
      end

      def render_error_card(row)
        render(Components::Card.new(padding: 0)) do
          div(class: 'error-card-body') do
            render_card_header(row)
            h3(class: 'error-card-title') { row[:issue_title] }
            render_cause_panel(row)
            render_technical_details(row)
          end
          render_card_footer(row)
        end
      end

      def render_card_header(row)
        div(class: 'error-card-header') do
          span(class: 'iid-mono') { plain "##{row[:issue_iid]}" }
          span(class: 'project-meta') { row[:project_path] }
          render status_pill(row[:status], size: :sm)
          span(class: 'when-meta') { relative_time(row[:created_at]) }
        end
      end

      def render_cause_panel(row)
        div(class: 'cause-panel') do
          span(class: 'cause-icon-box') do
            render Components::Icon.new(name: 'alert-tri', size: 14)
          end
          div do
            div(class: 'cause-title') { t_web(cause_key(row)) }
            div(class: 'cause-body') { t_web(explain_key(row)) }
          end
        end
      end

      # Map a row to the correct cause/explanation pair based on which field
      # surfaced the problem.
      def cause_key(row)
        return :web_errors_cause_post_completion if row[:post_completion_error]
        return :web_errors_cause_clarification   if row[:status] == 'needs_clarification'

        :web_errors_cause_failure
      end

      def explain_key(row)
        return :web_errors_explain_post_completion if row[:post_completion_error]
        return :web_errors_explain_clarification   if row[:status] == 'needs_clarification'

        :web_errors_explain_failure
      end

      def render_technical_details(row)
        msg = row[:error_message] || row[:post_completion_error]
        return if msg.nil? || msg.to_s.empty?

        details(class: 'technical-details') do
          summary(class: 'technical-summary') do
            render Components::Icon.new(name: 'chevron-d', size: 12, stroke_width: 2)
            plain " #{t_web(:web_errors_show_technical)}"
          end
          pre(class: 'technical-pre') { msg.to_s }
        end
      end

      def render_card_footer(row)
        div(class: 'error-card-footer') do
          render_avatar_strip(row)
          div(class: 'footer-actions') do
            render Components::Button.new(size: :sm, href: "/issues/#{row[:id]}") do
              t_web(:web_errors_view_detail)
            end
            render_suggested_action(row)
          end
        end
      end

      def render_avatar_strip(row)
        author = row[:issue_author_id] ? "##{row[:issue_author_id]}" : '—'
        div(class: 'avatar-strip') do
          span(class: 'avatar') { plain author[0..1] }
          span(class: 'requester-text') { t_web(:web_errors_requester, iid: row[:issue_iid]) }
        end
      end

      def render_suggested_action(row)
        if row[:status] == 'needs_clarification'
          # "Voir la question" → the GitLab issue where the question was posted
          # and where the user actually replies. Falls back to the local detail
          # page if no gitlab_url is configured.
          href = gitlab_issue_url(row) || "/issues/#{row[:id]}"
          render Components::Button.new(kind: :primary, size: :sm,
                                        icon: Components::Icon.new(name: 'messages', size: 13),
                                        href: href) do
            t_web(:web_errors_action_view_question)
          end
        else
          render_retry_form(row)
        end
      end

      def render_retry_form(row)
        form(method: 'post', action: "/issues/#{row[:id]}/reset", style: 'display: inline',
             data: { confirm: t_web(:web_errors_confirm_reset, iid: row[:issue_iid]) }) do
          csrf_input_tag
          button(type: 'submit', class: 'btn btn-primary-sm', style: retry_btn_style) do
            render Components::Icon.new(name: 'refresh', size: 13)
            plain ' '
            plain t_web(:web_errors_action_retry)
          end
        end
      end

      def retry_btn_style
        'display: inline-flex; align-items: center; justify-content: center; gap: 6px; ' \
          'padding: 5px 10px; font-size: 12px; font-weight: 500; ' \
          'border-radius: var(--r-sm); ' \
          'background: var(--accent-solid); color: var(--text-on-accent); ' \
          'border: 1px solid var(--accent-solid-hover); cursor: pointer;'
      end
    end
  end
end
