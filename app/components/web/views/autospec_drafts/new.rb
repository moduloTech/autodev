# frozen_string_literal: true

module Web
  module Views
    module AutospecDrafts
      # GET /autospec_drafts/new — form to start a draft. 10a minimum:
      # the CSM picks a project and optionally a title + initial markdown.
      # The chat conversation and the editor proper live on the show page
      # once the row exists.
      class New < Web::Views::Base
        def initialize(projects:, **)
          super(**)
          @projects = projects
        end

        def view_template # rubocop:disable Metrics/MethodLength
          with_layout(nav: false, shell: false) do
            div(class: 'app-shell') do
              render_sidebar
              main do
                render_topbar
                div(style: 'flex: 1; overflow: auto; padding: 28px; max-width: 820px;') do
                  @projects.any? ? render_form : render_no_projects
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
            title: t_web(:web_autospec_new_title),
            subtitle: t_web(:web_autospec_new_subtitle),
            breadcrumb: t_web(:web_autospec_index_title)
          )
        end

        def render_no_projects
          render Components::Card.new(padding: 24) do
            p(class: 'muted', style: 'margin: 0;') { t_web(:web_autospec_no_projects) }
          end
        end

        def render_form
          render Components::Card.new(padding: 24) do
            form(action: '/autospec_drafts', method: 'post',
                 style: 'display: grid; gap: 16px;') do
              csrf_input_tag
              render_project_field
              render_title_field
              render_markdown_field
              render_submit_row
            end
          end
        end

        def render_project_field
          label(style: 'display: grid; gap: 6px;') do
            span(style: label_style) { t_web(:web_autospec_field_project) }
            select(name: 'project_id', required: true, style: input_style) do
              option(value: '') { t_web(:web_autospec_field_project_prompt) }
              @projects.each { |p| option(value: p.id.to_s) { p.gitlab_path } }
            end
          end
        end

        def render_title_field
          label(style: 'display: grid; gap: 6px;') do
            span(style: label_style) { t_web(:web_autospec_field_title) }
            input(type: 'text', name: 'title',
                  placeholder: t_web(:web_autospec_field_title_placeholder),
                  style: input_style)
          end
        end

        def render_markdown_field
          label(style: 'display: grid; gap: 6px;') do
            span(style: label_style) { t_web(:web_autospec_field_markdown) }
            textarea(name: 'markdown', rows: '8',
                     style: "#{input_style} font-family: var(--font-mono); font-size: 13px;",
                     placeholder: t_web(:web_autospec_field_markdown_placeholder))
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
              t_web(:web_autospec_create)
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
            'color: var(--text); width: 100%; box-sizing: border-box;'
        end
      end
    end
  end
end
