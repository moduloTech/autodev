# frozen_string_literal: true

module Web
  module Views
    module AutospecDrafts
      # GET /autospec_drafts/import — form to backfill an AutoSpec
      # draft from an existing GitLab issue URL (autospec.md §A "very
      # nice to have"). Pre-populates title + markdown from the
      # source ticket; the operator then iterates on the draft like
      # any other.
      class Import < Web::Views::Base
        def view_template # rubocop:disable Metrics/MethodLength
          with_layout(nav: false, shell: false) do
            div(class: 'app-shell') do
              render_sidebar
              main do
                render_topbar
                div(style: 'flex: 1; overflow: auto; padding: 28px; max-width: 720px;') do
                  render_form
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
            title: t_web(:web_autospec_import_title),
            subtitle: t_web(:web_autospec_import_subtitle),
            breadcrumb: t_web(:web_autospec_index_title)
          )
        end

        def render_form
          render Components::Card.new(padding: 24) do
            form(action: '/autospec_drafts/import', method: 'post',
                 style: 'display: grid; gap: 16px;') do
              csrf_input_tag
              render_url_field
              render_submit_row
            end
          end
        end

        def render_url_field
          label(style: 'display: grid; gap: 6px;') do
            span(style: label_style) { t_web(:web_autospec_import_field_url) }
            input(type: 'url', name: 'url', required: true,
                  placeholder: t_web(:web_autospec_import_field_url_placeholder),
                  style: input_style)
            span(class: 'muted', style: 'font-size: 11px;') do
              t_web(:web_autospec_import_field_url_hint)
            end
          end
        end

        def render_submit_row
          div(style: 'display: flex; justify-content: flex-end; gap: 10px;') do
            a(href: '/autospec_drafts', class: 'button',
              style: 'padding: 8px 14px; font-size: 13px;') do
              t_web(:web_autospec_cancel)
            end
            button(type: 'submit', class: 'button button-primary',
                   style: 'padding: 8px 14px; font-size: 13px;') do
              t_web(:web_autospec_import_submit)
            end
          end
        end

        def label_style
          'font-size: 12px; font-weight: 600; color: var(--text-muted); ' \
            'text-transform: uppercase; letter-spacing: 0.04em;'
        end

        def input_style
          'background: var(--paper-2); border: 1px solid var(--border); ' \
            'border-radius: var(--r-md); padding: 9px 12px; font-size: 13px; ' \
            'color: var(--text); width: 100%; box-sizing: border-box; ' \
            'font-family: var(--font-mono);'
        end
      end
    end
  end
end
