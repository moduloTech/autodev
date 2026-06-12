# frozen_string_literal: true

module Web
  module Views
    module AutospecDrafts
      # GET /autospec_drafts/:id — main draft workspace (step 10a).
      #
      # Single column for 10a: meta card → markdown read-only card →
      # conversation card (message history + composer + inline
      # apply-suggestion buttons). The two-column desktop layout
      # (editor centre, chat right) is the visual target of 10b/10c
      # along with the markdown editor + drag-drop attachments.
      class Show < Web::Views::Base # rubocop:disable Metrics/ClassLength
        def initialize(draft:, messages:, **)
          super(**)
          @draft = draft
          @messages = messages
        end

        def view_template # rubocop:disable Metrics/MethodLength
          with_layout(nav: false, shell: false) do
            div(class: 'app-shell') do
              render_sidebar
              main do
                render_topbar
                div(style: 'flex: 1; overflow: auto; padding: 28px; max-width: 920px;') do
                  div(style: 'display: grid; gap: 16px;') do
                    render_meta_card
                    render_markdown_card
                    render_conversation_card
                  end
                end
              end
            end
          end
        end

        private

        def render_sidebar
          render Components::Sidebar.new(
            active: 'chat', locale: web_locale, request_path: @request_path,
            counts: {}, admin: @current_user_admin,
            translator: ->(key, **vars) { t_web(key, **vars) },
            current_user_email: @current_user_email, csrf_token: @csrf_token
          )
        end

        def render_topbar
          render Components::Topbar.new(
            title: @draft.title.presence || t_web(:web_autospec_untitled),
            subtitle: @draft.project.gitlab_path,
            breadcrumb: t_web(:web_autospec_index_title)
          )
        end

        def render_meta_card # rubocop:disable Metrics/AbcSize
          render Components::Card.new(padding: 16) do
            div(style: 'display: flex; flex-wrap: wrap; gap: 18px; font-size: 12px;') do
              meta_field(t_web(:web_autospec_meta_status), t_web(status_label_key))
              meta_field(t_web(:web_autospec_meta_iteration), @draft.current_iteration.to_s)
              meta_field(t_web(:web_autospec_meta_destination),
                         @draft.destination.presence || '—')
              meta_field(t_web(:web_autospec_meta_project), @draft.project.gitlab_path)
            end
          end
        end

        def meta_field(label, value)
          div do
            div(class: 'muted', style: 'font-size: 10.5px; text-transform: uppercase; ' \
                                       'letter-spacing: 0.04em;') { label }
            div(style: 'font-weight: 500; margin-top: 2px;') { plain value }
          end
        end

        def render_markdown_card
          render Components::Card.new(padding: 20) do
            div(class: 'muted', style: 'font-size: 11px; text-transform: uppercase; ' \
                                       'letter-spacing: 0.04em; margin-bottom: 10px;') do
              t_web(:web_autospec_section_markdown)
            end
            pre(style: pre_style) { plain(@draft.markdown.presence || t_web(:web_autospec_markdown_empty)) }
          end
        end

        def render_conversation_card
          render Components::Card.new(padding: 0) do
            div(style: 'padding: 16px 20px; border-bottom: 1px solid var(--border); ' \
                       'font-size: 11px; text-transform: uppercase; ' \
                       'letter-spacing: 0.04em; color: var(--text-muted);') do
              t_web(:web_autospec_section_conversation)
            end
            render_messages
            render_composer
          end
        end

        def render_messages
          div(style: 'padding: 16px 20px; display: flex; flex-direction: column; gap: 14px;') do
            if @messages.empty?
              p(class: 'muted', style: 'margin: 0; font-size: 13px;') do
                t_web(:web_autospec_conversation_empty)
              end
            else
              @messages.each { |m| render_message(m) }
            end
          end
        end

        def render_message(msg)
          assistant = msg.role == 'assistant'
          div(style: message_row_style(assistant)) do
            div(style: bubble_style(assistant)) do
              plain(msg.content.presence || '')
            end
            render_tool_calls(msg) if assistant && msg.tool_calls.any?
          end
        end

        def render_tool_calls(msg)
          div(style: 'display: flex; flex-wrap: wrap; gap: 6px; margin-top: 6px;') do
            msg.tool_calls.each { |call| render_tool_call_button(msg, call) }
          end
        end

        def render_tool_call_button(msg, call) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
          applied = call['applied_at'].present?
          form(action: "/autospec_drafts/#{@draft.id}/apply_suggestion", method: 'post') do
            csrf_input_tag
            input(type: 'hidden', name: 'message_id', value: msg.id.to_s)
            input(type: 'hidden', name: 'tool_use_id', value: call['id'].to_s)
            button(type: 'submit', disabled: applied,
                   style: apply_button_style(applied)) do
              plain(applied ? "✓ #{call.dig('input',
                                            'summary') || call['name']}" : (call.dig('input',
                                                                                     'summary') || call['name']))
            end
          end
        end

        def render_composer # rubocop:disable Metrics/MethodLength
          form(action: "/autospec_drafts/#{@draft.id}/chat", method: 'post',
               style: 'padding: 12px 20px; border-top: 1px solid var(--border); ' \
                      'display: grid; gap: 8px;') do
            csrf_input_tag
            textarea(name: 'message', rows: '3',
                     placeholder: t_web(:web_autospec_composer_placeholder),
                     required: true, style: composer_textarea_style)
            div(style: 'display: flex; justify-content: flex-end;') do
              button(type: 'submit', class: 'button button-primary',
                     style: 'padding: 7px 14px; font-size: 13px;') do
                t_web(:web_autospec_composer_send)
              end
            end
          end
        end

        def status_label_key
          {
            'drafting' => :web_autospec_status_drafting,
            'pending_approval' => :web_autospec_status_pending_approval,
            'rejected' => :web_autospec_status_rejected,
            'submitted' => :web_autospec_status_submitted
          }.fetch(@draft.status.to_s, :web_autospec_status_drafting)
        end

        def pre_style
          'margin: 0; padding: 16px; background: var(--paper-2); ' \
            'border: 1px solid var(--border); border-radius: var(--r-md); ' \
            'font-family: var(--font-mono); font-size: 12.5px; line-height: 1.55; ' \
            'white-space: pre-wrap; word-wrap: break-word;'
        end

        def message_row_style(assistant)
          align = assistant ? 'flex-start' : 'flex-end'
          "display: flex; flex-direction: column; align-items: #{align}; max-width: 80%; " \
            "#{assistant ? 'margin-right: auto;' : 'margin-left: auto;'}"
        end

        def bubble_style(assistant)
          bg = assistant ? 'var(--accent-bg)' : 'var(--paper-2)'
          border = assistant ? 'var(--accent-bg-strong)' : 'var(--border)'
          "background: #{bg}; border: 1px solid #{border}; " \
            'border-radius: 12px; padding: 9px 12px; font-size: 13px; line-height: 1.55; ' \
            'white-space: pre-wrap; word-wrap: break-word;'
        end

        def apply_button_style(applied)
          opacity = applied ? '0.55' : '1'
          'background: var(--paper); border: 1px dashed var(--accent-solid); ' \
            'color: var(--accent-fg); padding: 5px 10px; border-radius: 999px; ' \
            "font-size: 11.5px; cursor: #{applied ? 'default' : 'pointer'}; opacity: #{opacity};"
        end

        def composer_textarea_style
          'background: var(--paper-2); border: 1px solid var(--border); ' \
            'border-radius: var(--r-md); padding: 8px 10px; font-size: 13px; ' \
            'font-family: inherit; resize: vertical; width: 100%; box-sizing: border-box;'
        end
      end
    end
  end
end
