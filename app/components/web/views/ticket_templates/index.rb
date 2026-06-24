# frozen_string_literal: true

module Web
  module Views
    module TicketTemplates
      # GET /projects/:slug/ticket_templates — list a project's ticket
      # templates (task #14), with new / edit / delete actions. Mirrors
      # the ProjectEdit chrome (sidebar + topbar + cards). Reachable by a
      # project collaborator or admin.
      class Index < Base
        def initialize(project:, templates:, **)
          super(**)
          @project = project
          @templates = templates
        end

        def view_template # rubocop:disable Metrics/MethodLength
          with_layout(nav: false, shell: false) do
            div(class: 'app-shell') do
              render_sidebar
              main do
                render_topbar
                div(style: 'flex: 1; overflow: auto; padding: 28px; max-width: 900px;') do
                  @templates.any? ? render_list : render_empty
                end
              end
            end
          end
        end

        private

        def render_sidebar
          render Components::Sidebar.new(
            active: 'projects', locale: web_locale, request_path: @request_path,
            counts: {}, admin: @current_user_admin,
            translator: ->(key, **vars) { t_web(key, **vars) },
            current_user_email: @current_user_email, csrf_token: @csrf_token
          )
        end

        def render_topbar
          root = t_web(:web_project_breadcrumb_root)
          render(Components::Topbar.new(
                   title: t_web(:web_ticket_templates_title, path: @project.gitlab_path),
                   subtitle: t_web(:web_ticket_templates_subtitle),
                   breadcrumb: "#{root} › #{@project.gitlab_path}"
                 )) do
            a(href: new_path, class: 'button button-primary', style: 'padding: 8px 14px; font-size: 13px;') do
              t_web(:web_ticket_templates_new)
            end
          end
        end

        def render_empty
          render(Components::Card.new(padding: 28)) do
            p(class: 'muted', style: 'margin: 0 0 12px;') { t_web(:web_ticket_templates_empty) }
            a(href: new_path, class: 'button button-primary', style: 'padding: 8px 14px; font-size: 13px;') do
              t_web(:web_ticket_templates_new)
            end
          end
        end

        def render_list
          div(style: 'display: grid; gap: 12px;') do
            @templates.each { |tpl| render_row(tpl) }
          end
        end

        def render_row(tpl) # rubocop:disable Metrics/MethodLength
          render(Components::Card.new(padding: 16)) do
            div(style: 'display: flex; justify-content: space-between; align-items: center; gap: 16px;') do
              div(style: 'min-width: 0; flex: 1;') do
                div(style: 'font-weight: 600; font-size: 14px;') { plain tpl.name }
                div(class: 'muted', style: 'font-size: 12px; margin-top: 2px; font-family: var(--font-mono);') do
                  plain tpl.slug
                end
              end
              render_row_actions(tpl)
            end
          end
        end

        def render_row_actions(tpl)
          div(style: 'display: flex; gap: 8px; flex-shrink: 0;') do
            a(href: edit_path(tpl), class: 'button', style: 'padding: 6px 12px; font-size: 12px;') do
              t_web(:web_ticket_templates_edit)
            end
            render_delete_form(tpl)
          end
        end

        def render_delete_form(tpl)
          form(action: member_path(tpl), method: 'post', style: 'display: inline;') do
            csrf_input_tag
            input(type: 'hidden', name: '_method', value: 'delete')
            button(type: 'submit', class: 'button button-danger', style: 'padding: 6px 12px; font-size: 12px;') do
              t_web(:web_ticket_templates_delete)
            end
          end
        end

        def base_path = "/projects/#{@project.slug}/ticket_templates"
        def new_path = "#{base_path}/new"
        def member_path(tpl) = "#{base_path}/#{tpl.id}"
        def edit_path(tpl) = "#{member_path(tpl)}/edit"
      end
    end
  end
end
