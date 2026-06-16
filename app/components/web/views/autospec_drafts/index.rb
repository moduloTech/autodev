# frozen_string_literal: true

module Web
  module Views
    module AutospecDrafts
      # GET /autospec_drafts — listing of the signed-in user's drafts
      # (step 10a — phase D AutoSpec). The full visual target (chat pane
      # right, editor centre, sidebar 240px — cf. docs/design/spec_update/
      # README.md) lands in step 10b/10c; this 10a slice is single-column
      # and reuses the existing Card / Sidebar / Topbar primitives.
      class Index < Web::Views::Base
        def initialize(drafts:, **)
          super(**)
          @drafts = drafts
        end

        def view_template # rubocop:disable Metrics/MethodLength
          with_layout(nav: false, shell: false) do
            div(class: 'app-shell') do
              render_sidebar
              main do
                render_topbar
                div(style: 'flex: 1; overflow: auto; padding: 28px;') do
                  @drafts.any? ? render_list : render_empty
                end
              end
            end
          end
        end

        private

        def render_sidebar
          render Components::Sidebar.new(
            active: 'chat', locale: web_locale, request_path: @request_path,
            counts: { chat: @drafts.size }, admin: @current_user_admin,
            translator: ->(key, **vars) { t_web(key, **vars) },
            current_user_email: @current_user_email, csrf_token: @csrf_token
          )
        end

        def render_topbar # rubocop:disable Metrics/MethodLength
          render Components::Topbar.new(
            title: t_web(:web_autospec_index_title),
            subtitle: t_web(:web_autospec_index_subtitle)
          ) do
            a(href: '/autospec_drafts/import', class: 'button',
              style: 'padding: 8px 14px; font-size: 13px;') do
              t_web(:web_autospec_import_cta)
            end
            a(href: '/autospec_drafts/new', class: 'button button-primary',
              style: 'padding: 8px 14px; font-size: 13px;') do
              t_web(:web_autospec_new_cta)
            end
          end
        end

        def render_empty
          render Components::Card.new(padding: 32) do
            p(class: 'muted', style: 'margin: 0 0 12px;') { t_web(:web_autospec_index_empty) }
            a(href: '/autospec_drafts/new', class: 'button button-primary',
              style: 'padding: 8px 14px; font-size: 13px;') do
              t_web(:web_autospec_new_cta)
            end
          end
        end

        def render_list
          div(style: 'display: grid; gap: 12px;') do
            @drafts.each { |d| render_row(d) }
          end
        end

        def render_row(draft)
          a(href: "/autospec_drafts/#{draft.id}",
            style: 'text-decoration: none; color: inherit; display: block;') do
            render Components::Card.new(padding: 16) do
              render_row_body(draft)
            end
          end
        end

        def render_row_body(draft) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
          div(style: 'display: flex; justify-content: space-between; align-items: center; gap: 16px;') do
            div(style: 'min-width: 0; flex: 1;') do
              div(style: 'font-weight: 600; font-size: 14px;') do
                plain(draft.title.presence || t_web(:web_autospec_untitled))
              end
              div(class: 'muted', style: 'font-size: 12px; margin-top: 2px;') do
                plain "#{draft.project.gitlab_path} · #{t_web(status_label_key(draft.status))}"
              end
            end
            div(class: 'muted', style: 'font-size: 11px;') do
              plain I18n.l(draft.updated_at, format: :short)
            rescue StandardError
              plain draft.updated_at.to_s
            end
          end
        end

        def status_label_key(status)
          {
            'drafting' => :web_autospec_status_drafting,
            'pending_approval' => :web_autospec_status_pending_approval,
            'rejected' => :web_autospec_status_rejected,
            'submitted' => :web_autospec_status_submitted
          }.fetch(status.to_s, :web_autospec_status_drafting)
        end
      end
    end
  end
end
