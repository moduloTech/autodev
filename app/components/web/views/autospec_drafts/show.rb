# frozen_string_literal: true

module Web
  module Views
    module AutospecDrafts
      # GET /autospec_drafts/:id — editor workspace (step 10b).
      #
      # Two-column layout: editor centre (toolbar + meta chips + title +
      # markdown textarea/preview + footer hint) and chat right (kept
      # identical to step 10a — message bubbles + composer + inline
      # apply-suggestion buttons). The mobile-tabs layout (Édition |
      # Discussion under the topbar) is 10c work.
      #
      # The textarea + preview pane are both rendered server-side so the
      # view is usable without JS — the textarea is the default visible
      # pane and `autospec.js` toggles `hidden` on each pane to switch
      # modes. Autosave (PATCH /autospec_drafts/:id) and the format
      # buttons / ⌘+B/I/K shortcuts live in autospec.js too.
      class Show < Web::Views::Base # rubocop:disable Metrics/ClassLength
        FORMAT_BUTTONS = [
          { key: 'bold',    label: 'B',    label_key: :web_autospec_format_bold,    style: 'font-weight: 700;' },
          { key: 'italic',  label: 'I',    label_key: :web_autospec_format_italic,  style: 'font-style: italic;' },
          { key: 'code',    label: '</>',  label_key: :web_autospec_format_code,
            style: 'font-family: var(--font-mono); font-size: 11px;' },
          { key: 'heading', label: 'H',    label_key: :web_autospec_format_heading, style: '' },
          { key: 'list',    label: '•',    label_key: :web_autospec_format_list,    style: 'font-size: 14px;' },
          { key: 'quote',   label: '“',    label_key: :web_autospec_format_quote,   style: 'font-size: 16px;' },
          { key: 'link',    label: '🔗', label_key: :web_autospec_format_link, style: 'font-size: 11px;' }
        ].freeze
        private_constant :FORMAT_BUTTONS

        # Static editable meta-chip definitions. Mirrors
        # `Autospec::SuggestionApplier::META_KEYS` minus tags (handled
        # separately as a list). `:options` drives the inline <select>
        # JS swaps in on click; `nil` → free-text <input>.
        META_CHIPS = [
          { key: 'type',     label_key: :web_autospec_meta_chip_type,
            options_key: :web_autospec_meta_chip_type_options },
          { key: 'priority', label_key: :web_autospec_meta_chip_priority,
            options_key: :web_autospec_meta_chip_priority_options }
        ].freeze
        private_constant :META_CHIPS

        def initialize(draft:, messages:, attachments: [], chat_enabled: true, **)
          super(**)
          @draft = draft
          @messages = messages
          @attachments = attachments
          @chat_enabled = chat_enabled
        end

        def view_template
          with_layout(nav: false, shell: false) { render_page }
        end

        private

        def render_page
          div(class: 'app-shell') do
            render_sidebar
            main do
              render_topbar
              render_workspace
            end
          end
          script(src: '/assets/js/autospec.js', defer: true)
        end

        def render_workspace
          div(class: 'autospec-workspace',
              data: { 'autospec-draft-id' => @draft.id.to_s,
                      'autospec-locked' => (@draft.drafting? ? 'false' : 'true'),
                      'autospec-active-tab' => 'edit' }) do
            render_mobile_tabs
            render_editor_column
            render_chat_column
          end
        end

        # Mobile-only tab bar (≤ 960 px). Hidden on desktop via CSS;
        # the JS reacts to clicks by flipping `data-autospec-active-tab`
        # on the workspace, which the same CSS file uses to show only
        # the matching column.
        def render_mobile_tabs
          div(class: 'autospec-mobile-tabs', role: 'tablist') do
            mobile_tab_button('edit', :web_autospec_tab_mobile_edit, selected: true)
            mobile_tab_button('chat', :web_autospec_tab_mobile_chat, selected: false)
          end
        end

        def mobile_tab_button(key, label_key, selected:)
          button(type: 'button', role: 'tab',
                 class: 'autospec-mobile-tab',
                 'aria-selected' => selected.to_s,
                 data: { 'autospec-mobile-tab' => key }) do
            t_web(label_key)
          end
        end

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

        # ── Editor column ─────────────────────────────────────────

        def render_editor_column # rubocop:disable Metrics/MethodLength
          div(class: 'autospec-editor-col',
              data: { 'autospec-editor-col' => 'true' }) do
            render_editor_toolbar
            div(class: 'autospec-editor-body') do
              render_meta_chips_row
              render_title_input
              render_editor_pane
              render_preview_pane
              render_attachments_section
              render_footer_hint
            end
            render_dropzone_overlay
          end
        end

        def render_attachments_section # rubocop:disable Metrics/MethodLength
          div(class: 'autospec-attachments',
              data: { 'autospec-attachments' => 'true' }) do
            div(class: 'muted',
                style: 'font-size: 11px; text-transform: uppercase; ' \
                       'letter-spacing: 0.04em; margin-bottom: 8px;') do
              t_web(:web_autospec_attachments_label, count: @attachments.size)
            end
            div(class: 'autospec-attachments-grid',
                data: { 'autospec-attachments-grid' => 'true' }) do
              @attachments.each { |att| render_attachment_card(att) }
              render_drop_target
            end
          end
        end

        def render_attachment_card(attachment)
          blob = attachment.file.blob
          url  = Rails.application.routes.url_helpers.rails_blob_path(attachment.file, only_path: true)
          div(class: 'autospec-attachment-card',
              data: { 'autospec-attachment-id' => attachment.id.to_s,
                      'autospec-attachment-markdown' => "![#{blob.filename}](#{url})" }) do
            render_attachment_preview(url, blob.filename.to_s)
            render_attachment_delete
            render_attachment_footer(blob)
          end
        end

        def render_attachment_preview(url, alt)
          div(class: 'autospec-attachment-preview') do
            img(src: url, alt: alt, loading: 'lazy')
          end
        end

        def render_attachment_delete
          button(type: 'button', class: 'autospec-attachment-delete',
                 'aria-label' => t_web(:web_autospec_attachment_delete),
                 title: t_web(:web_autospec_attachment_delete),
                 data: { 'autospec-attachment-delete' => 'true' }) { plain '✕' }
        end

        def render_attachment_footer(blob) # rubocop:disable Metrics/MethodLength
          div(class: 'autospec-attachment-footer') do
            div(class: 'autospec-attachment-filename', title: blob.filename.to_s) do
              plain blob.filename.to_s
            end
            div(class: 'autospec-attachment-meta') do
              plain humanise_size(blob.byte_size)
              button(type: 'button', class: 'autospec-attachment-copy',
                     title: t_web(:web_autospec_attachment_copy_markdown),
                     data: { 'autospec-attachment-copy' => 'true' }) { plain '⧉' }
            end
          end
        end

        def render_drop_target
          div(class: 'autospec-drop-target',
              data: { 'autospec-drop-target' => 'true' }) do
            div(style: 'font-size: 13px; font-weight: 500;') do
              t_web(:web_autospec_attachment_drop_here)
            end
            div(class: 'muted', style: 'font-size: 11px; margin-top: 2px;') do
              t_web(:web_autospec_attachment_drop_hint)
            end
          end
        end

        def render_dropzone_overlay # rubocop:disable Metrics/MethodLength
          div(class: 'autospec-dropzone-overlay',
              data: { 'autospec-dropzone-overlay' => 'true' }) do
            div(class: 'autospec-dropzone-card') do
              div(style: 'font-size: 26px;') { plain '🖼️' }
              div(style: 'font-size: 14px; font-weight: 600; margin-top: 6px;') do
                t_web(:web_autospec_attachment_drop_here)
              end
              div(class: 'muted', style: 'font-size: 12px; margin-top: 2px;') do
                t_web(:web_autospec_attachment_drop_hint)
              end
            end
          end
        end

        # Format bytes for the AttachmentCard footer. KB / MB rounded to
        # one decimal — the design specs ask for "dims × size", but
        # without ImageMagick we don't have dims, so just size.
        def humanise_size(bytes)
          return "#{bytes} B" if bytes < 1024
          return "#{(bytes / 1024.0).round(1)} KB" if bytes < 1_048_576

          "#{(bytes / 1_048_576.0).round(1)} MB"
        end

        def render_editor_toolbar
          div(class: 'autospec-editor-toolbar') do
            render_tabs
            render_format_bar
            render_save_indicator
          end
        end

        def render_tabs
          div(class: 'autospec-tabs', role: 'tablist') do
            tab_button('edit', :web_autospec_tab_edit, selected: true)
            tab_button('preview', :web_autospec_tab_preview, selected: false)
          end
        end

        def tab_button(key, label_key, selected:)
          button(type: 'button', role: 'tab',
                 class: 'autospec-tab',
                 'aria-selected' => selected.to_s,
                 data: { 'autospec-tab' => key }) do
            t_web(label_key)
          end
        end

        def render_format_bar
          div(class: 'autospec-format-bar', data: { 'autospec-format-bar' => 'true' }) do
            FORMAT_BUTTONS.each { |btn| format_button(btn) }
          end
        end

        def format_button(btn)
          button(type: 'button', class: 'autospec-format-btn',
                 'aria-label' => t_web(btn[:label_key]), title: t_web(btn[:label_key]),
                 data: { 'autospec-format' => btn[:key] },
                 style: btn[:style]) { plain btn[:label] }
        end

        def render_save_indicator
          state = @draft.drafting? ? 'idle' : 'locked'
          label_key = @draft.drafting? ? :web_autospec_save_idle : :web_autospec_save_locked
          div(class: 'autospec-save-indicator',
              data: { 'autospec-save-indicator' => 'true', state: state }) do
            span(class: 'autospec-save-dot')
            span(data: { 'autospec-save-label' => 'true' }) { t_web(label_key) }
          end
        end

        # ── Meta chips ────────────────────────────────────────────

        def render_meta_chips_row
          div(class: 'autospec-meta-row') do
            META_CHIPS.each { |chip| render_meta_chip(chip) }
            render_tags_chip
            render_static_meta
          end
        end

        def render_meta_chip(chip)
          value = (@draft.meta_chips || {})[chip[:key]].to_s
          options = t_web(chip[:options_key]).to_s
          div(class: 'autospec-chip',
              data: { 'autospec-chip' => chip[:key], 'autospec-chip-options' => options }) do
            span(class: 'autospec-chip-label') { t_web(chip[:label_key]) }
            span(class: 'autospec-chip-value', data: { 'autospec-chip-value' => 'true' }) do
              plain(value.presence || t_web(:web_autospec_meta_chip_empty))
            end
          end
        end

        def render_tags_chip
          tags = Array((@draft.meta_chips || {})['tags']).compact_blank
          div(class: 'autospec-chip', data: { 'autospec-chip' => 'tags' }) do
            span(class: 'autospec-chip-label') { t_web(:web_autospec_meta_chip_tags) }
            span(class: 'autospec-chip-value', data: { 'autospec-chip-value' => 'true' }) do
              plain(tags.any? ? tags.map { |t| "##{t}" }.join(' ') : t_web(:web_autospec_meta_chip_empty))
            end
          end
        end

        # Read-only context chips (status + iteration) — these are
        # state, not editable metadata. Iteration is bumped by the
        # AASM event `submit_for_approval`, status by every transition.
        def render_static_meta
          span(class: 'autospec-chip',
               style: 'cursor: default; background: var(--paper-2);') do
            span(class: 'autospec-chip-label') { t_web(:web_autospec_meta_status) }
            span(class: 'autospec-chip-value') { plain t_web(status_label_key) }
          end
          span(class: 'autospec-chip',
               style: 'cursor: default; background: var(--paper-2);') do
            span(class: 'autospec-chip-label') { t_web(:web_autospec_meta_iteration) }
            span(class: 'autospec-chip-value') { plain @draft.current_iteration.to_s }
          end
        end

        # ── Title + editor + preview panes ────────────────────────

        def render_title_input
          input(type: 'text', class: 'autospec-title-input',
                value: @draft.title.to_s,
                placeholder: t_web(:web_autospec_title_placeholder),
                data: { 'autospec-field' => 'title' },
                disabled: @draft.drafting? ? nil : 'disabled')
        end

        def render_editor_pane
          div(class: 'autospec-pane', data: { 'autospec-pane' => 'edit' }) do
            textarea(class: 'autospec-textarea',
                     data: { 'autospec-field' => 'markdown' },
                     placeholder: t_web(:web_autospec_markdown_empty),
                     disabled: @draft.drafting? ? nil : 'disabled') do
              plain(@draft.markdown.to_s)
            end
          end
        end

        # Server-rendered preview HTML. Hidden by default — clicking
        # Aperçu toggles `hidden`. `autospec.js` refreshes the inner
        # HTML after every autosave so the preview matches whatever is
        # in the textarea.
        def render_preview_pane
          div(class: 'autospec-pane', data: { 'autospec-pane' => 'preview' }, hidden: true) do
            div(class: 'autospec-preview', data: { 'autospec-preview' => 'true' }) do
              if @draft.markdown.present?
                raw safe(Autospec::MarkdownRenderer.render(@draft.markdown))
              else
                p(class: 'muted', style: 'margin: 0;') { t_web(:web_autospec_preview_empty) }
              end
            end
          end
        end

        def render_footer_hint
          div(class: 'autospec-footer-hint') { plain t_web(:web_autospec_footer_hint) }
        end

        # ── Chat column ───────────────────────────────────────────

        def render_chat_column
          div(class: 'autospec-chat-col') do
            div(style: 'padding: 14px 18px; border-bottom: 1px solid var(--border); ' \
                       'font-size: 11px; text-transform: uppercase; ' \
                       'letter-spacing: 0.04em; color: var(--text-muted);') do
              t_web(:web_autospec_section_conversation)
            end
            render_chat_disabled_notice unless @chat_enabled
            div(style: 'flex: 1; overflow: auto;') { render_messages }
            render_composer
          end
        end

        def render_chat_disabled_notice
          div(style: 'padding: 12px 18px; border-bottom: 1px solid var(--border); ' \
                     'background: var(--warn-bg); color: var(--warn-fg); ' \
                     'font-size: 12px; line-height: 1.5;') do
            div(style: 'font-weight: 600; margin-bottom: 2px;') do
              t_web(:web_autospec_chat_unavailable_title)
            end
            div { plain t_web(:web_autospec_chat_unavailable_hint) }
          end
        end

        def render_messages
          div(style: 'padding: 16px 18px; display: flex; flex-direction: column; gap: 14px;') do
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
               style: 'padding: 12px 18px; border-top: 1px solid var(--border); ' \
                      'display: grid; gap: 8px;') do
            csrf_input_tag
            textarea(name: 'message', rows: '3',
                     placeholder: composer_placeholder,
                     required: @chat_enabled ? true : nil,
                     disabled: @chat_enabled ? nil : 'disabled',
                     style: composer_textarea_style)
            div(style: 'display: flex; justify-content: flex-end;') do
              button(type: 'submit', class: 'button button-primary',
                     disabled: @chat_enabled ? nil : 'disabled',
                     style: composer_send_style) do
                t_web(:web_autospec_composer_send)
              end
            end
          end
        end

        def composer_placeholder
          @chat_enabled ? t_web(:web_autospec_composer_placeholder) : t_web(:web_autospec_chat_unavailable_title)
        end

        def composer_send_style
          base = 'padding: 7px 14px; font-size: 13px;'
          @chat_enabled ? base : "#{base} opacity: 0.55; cursor: not-allowed;"
        end

        # ── Style helpers ─────────────────────────────────────────

        def status_label_key
          {
            'drafting' => :web_autospec_status_drafting,
            'pending_approval' => :web_autospec_status_pending_approval,
            'rejected' => :web_autospec_status_rejected,
            'submitted' => :web_autospec_status_submitted
          }.fetch(@draft.status.to_s, :web_autospec_status_drafting)
        end

        def message_row_style(assistant)
          align = assistant ? 'flex-start' : 'flex-end'
          "display: flex; flex-direction: column; align-items: #{align}; max-width: 86%; " \
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
