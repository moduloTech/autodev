# frozen_string_literal: true

module Web
  module Views
    module Concerns
      # Rich "needs-a-human" card rendering, shared by the /issues tabs that
      # replace the old /errors page: `errors` (status error), `waiting`
      # (needs_clarification), and `delivered_review` (done + needs_attention
      # or a failed post-completion hook).
      #
      # Each card shows a cause panel (title + plain-language explanation),
      # collapsible technical details, and a context-specific call to action:
      # - waiting           → "Voir la question" (links to the GitLab issue)
      # - error             → "Réessayer maintenant" (reset → pending)
      # - delivered_review  → "Clôturer" (only for users who may close it)
      #
      # Host requirements: a Phlex view that `include`s Web::Helpers (i.e. a
      # Web::Views::Base subclass) and exposes `@issues`, `@current_user_admin`,
      # `@csrf_token`, and `@closable_ids` (a Set of issue ids the current user
      # is allowed to close). This is the single home for the watch-card
      # copy/CTA logic that used to live in the now-removed /errors page.
      module WatchCards # rubocop:disable Metrics/ModuleLength
        def render_watch_cards
          div(class: 'errors-cards') do
            @issues.each { |row| render_watch_card(row) }
          end
        end

        private

        def render_watch_card(row)
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
            render status_pill(issue_status(row), size: :sm)
            span(class: 'when-meta') { relative_time(row[:created_at]) }
          end
        end

        def render_cause_panel(row)
          div(class: cause_panel_class(row)) do
            span(class: 'cause-icon-box') do
              render Components::Icon.new(name: 'alert-tri', size: 14)
            end
            div { render_cause_panel_body(row) }
          end
        end

        def render_cause_panel_body(row)
          div(class: 'cause-title') { t_web(cause_key(row)) }
          div(class: 'cause-body') { t_web(explain_key(row)) }
          render_attention_detail(row)
          render_attention_contact(row)
        end

        # The concrete infra blocker (failing job + reason, e.g. "deploy_review
        # (script_failure)") captured on the stagnation bail-out. Only present on
        # needs_attention rows whose give-up path recorded it (currently the infra
        # pipeline path); rendered as a compact line under the plain-language cause
        # so the operator sees what to fix without opening the MR.
        def render_attention_detail(row)
          detail = row[:attention_detail]
          return if detail.nil? || detail.to_s.strip.empty?

          div(class: 'cause-detail') { t_web(:web_errors_attention_detail, detail: detail.to_s) }
        end

        # A delivered-but-flagged card (needs_attention) has no dedicated owner
        # by design — decision was a single common message rather than naming
        # a person or branching on attention_reason. Not shown on plain errors
        # or pending clarifications, only on the 4 needs_attention reasons.
        def render_attention_contact(row)
          return unless row[:needs_attention]

          div(class: 'cause-contact') { t_web(:web_errors_contact) }
        end

        # Technical failures (the errors tab) keep the red alert; a pending
        # question or a delivered-but-flagged request is a softer "heads up",
        # so its panel uses the yellow warn tone — matching the status badge.
        def cause_panel_class(row)
          row[:status].to_s == 'error' ? 'cause-panel' : 'cause-panel cause-panel--warn'
        end

        # Map a row to the correct cause/explanation pair based on which field
        # surfaced the problem.
        def cause_key(row)
          return :web_errors_cause_post_completion if row[:post_completion_error]
          return :web_errors_cause_clarification   if row[:status] == 'needs_clarification'
          return :web_errors_cause_attention       if row[:needs_attention]

          :web_errors_cause_failure
        end

        def explain_key(row)
          return :web_errors_explain_post_completion if row[:post_completion_error]
          return :web_errors_explain_clarification   if row[:status] == 'needs_clarification'
          return :"web_errors_explain_attention_#{row[:attention_reason]}" if row[:needs_attention]
          return :web_errors_explain_auth if auth_failure?(row)

          :web_errors_explain_failure
        end

        # An AuthenticationError (Claude 401) is stored with its class name in
        # error_message by the workers' handle_auth_failure. Retrying won't help
        # until credentials are restored, so the card gets a dedicated message and
        # the retry button is suppressed.
        def auth_failure?(row)
          row[:status] == 'error' && row[:error_message].to_s.include?('AuthenticationError')
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
          author = author_display(row)
          div(class: 'avatar-strip') do
            span(class: 'avatar') { plain author_initials(author) }
            span(class: 'requester-text') { t_web(:web_errors_requester, name: author) }
          end
        end

        # Context-specific primary CTA. `done` only ever reaches a watch card
        # via the delivered_review tab (done + needs_attention / post_completion),
        # so it maps to the "Clôturer" action.
        def render_suggested_action(row)
          case row[:status].to_s
          when 'needs_clarification' then render_view_question(row)
          when 'done'                then render_close_form(row)
          else                            render_retry_form(row)
          end
        end

        # "Voir la question" → the GitLab issue where the question was posted
        # and where the user actually replies. Falls back to the local detail
        # page if no gitlab_url is configured.
        def render_view_question(row)
          href = gitlab_issue_url(row) || "/issues/#{row[:id]}"
          render Components::Button.new(kind: :primary, size: :sm,
                                        icon: Components::Icon.new(name: 'messages', size: 13),
                                        href: href) do
            t_web(:web_errors_action_view_question)
          end
        end

        def render_retry_form(row)
          # Auth failures can't be retried until Claude is reconnected — hide the
          # button for regular users (the message says so), but keep it for admins
          # so they can re-kick the issue once they've restored the credentials.
          return if auth_failure?(row) && !@current_user_admin

          form(method: 'post', action: "/issues/#{row[:id]}/reset", style: 'display: inline',
               data: { confirm: t_web(:web_errors_confirm_reset, iid: row[:issue_iid]) }) do
            csrf_input_tag
            # Come back to the errors tab after the reset so the user can retry the
            # next failed issue without bouncing through each detail page.
            input(type: 'hidden', name: 'return_to', value: '/issues?tab=errors')
            render_retry_button
          end
        end

        def render_retry_button
          button(type: 'submit', class: 'btn btn-primary-sm', style: action_btn_style) do
            render Components::Icon.new(name: 'refresh', size: 13)
            plain ' '
            plain t_web(:web_errors_action_retry)
          end
        end

        # "Clôturer" → marks a delivered-but-flagged issue as closed (clears
        # needs_attention). Gated like IssuesController#close: only rendered for
        # users in @closable_ids (project collaborators + admins). Everyone else
        # sees just "Voir le détail".
        def render_close_form(row)
          return unless @closable_ids&.include?(row[:id])

          form(method: 'post', action: "/issues/#{row[:id]}/close", style: 'display: inline',
               data: { confirm: t_web(:web_errors_confirm_close, iid: row[:issue_iid]) }) do
            csrf_input_tag
            input(type: 'hidden', name: 'return_to', value: '/issues?tab=delivered_review')
            render_close_button
          end
        end

        def render_close_button
          button(type: 'submit', class: 'btn btn-primary-sm', style: action_btn_style) do
            render Components::Icon.new(name: 'check', size: 13)
            plain ' '
            plain t_web(:web_errors_action_close)
          end
        end

        def action_btn_style
          'display: inline-flex; align-items: center; justify-content: center; gap: 6px; ' \
            'padding: 5px 10px; font-size: 12px; font-weight: 500; ' \
            'border-radius: var(--r-sm); ' \
            'background: var(--accent-solid); color: var(--text-on-accent); ' \
            'border: 1px solid var(--accent-solid-hover); cursor: pointer;'
        end
      end
    end
  end
end
