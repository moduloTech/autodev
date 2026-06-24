# frozen_string_literal: true

module Web
  module Views
    module TicketTemplates
      # GET /projects/:slug/ticket_templates/new + /:id/edit — create or
      # edit a ticket template (task #14). Posts to the collection (create)
      # or member (update, with a _method=patch override) path. A failed
      # save re-renders with the submitted values + validation errors.
      class Form < Base # rubocop:disable Metrics/ClassLength
        def initialize(project:, template:, **)
          super(**)
          @project = project
          @template = template
        end

        def view_template # rubocop:disable Metrics/MethodLength
          with_layout(nav: false, shell: false) do
            div(class: 'app-shell') do
              render_sidebar
              main do
                render_topbar
                div(style: 'flex: 1; overflow: auto; padding: 28px; max-width: 820px;') do
                  render_error_banner if @template.errors.any?
                  render_form
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
          title_key = @template.new_record? ? :web_ticket_template_new_title : :web_ticket_template_edit_title
          render(Components::Topbar.new(
                   title: t_web(title_key),
                   subtitle: @project.gitlab_path,
                   breadcrumb: "#{root} › #{@project.gitlab_path} › #{t_web(:web_ticket_templates_title_short)}"
                 ))
        end

        def render_error_banner
          div(style: 'background: var(--err-bg); border: 1px solid var(--err-fg); ' \
                     'border-radius: var(--r-md); padding: 12px 14px; margin-bottom: 18px;') do
            p(style: 'margin: 0 0 6px; font-weight: 600; color: var(--err-fg); font-size: 13px;') do
              t_web(:web_ticket_template_error_banner)
            end
            ul(style: 'margin: 0; padding-left: 18px; font-size: 12px; color: var(--err-fg);') do
              @template.errors.full_messages.each { |msg| li { plain msg } }
            end
          end
        end

        def render_form
          render(Components::Card.new(padding: 24)) do
            form(action: form_action, method: 'post', style: 'display: grid; gap: 16px;') do
              csrf_input_tag
              input(type: 'hidden', name: '_method', value: 'patch') unless @template.new_record?
              render_name_field
              render_slug_field
              render_body_field
              render_submit_row
            end
          end
        end

        def form_action
          base = "/projects/#{@project.slug}/ticket_templates"
          @template.new_record? ? base : "#{base}/#{@template.id}"
        end

        def render_name_field
          field_shell(:web_ticket_template_field_name, :web_ticket_template_field_name_hint) do
            input(type: 'text', name: 'name', value: @template.name.to_s, required: true, style: input_style)
          end
        end

        def render_slug_field
          field_shell(:web_ticket_template_field_slug, :web_ticket_template_field_slug_hint) do
            input(type: 'text', name: 'template_slug', value: @template.slug.to_s,
                  style: "#{input_style} font-family: var(--font-mono);")
          end
        end

        def render_body_field
          field_shell(:web_ticket_template_field_body, :web_ticket_template_field_body_hint) do
            textarea(name: 'body', rows: '14',
                     style: "#{input_style} font-family: var(--font-mono); font-size: 13px;") do
              plain @template.body.to_s
            end
          end
        end

        def render_submit_row
          div(style: 'display: flex; justify-content: flex-end; gap: 10px;') do
            a(href: "/projects/#{@project.slug}/ticket_templates", class: 'button',
              style: 'padding: 8px 14px; font-size: 13px;') do
              t_web(:web_ticket_template_cancel)
            end
            button(type: 'submit', class: 'button button-primary', style: 'padding: 8px 14px; font-size: 13px;') do
              t_web(:web_ticket_template_save)
            end
          end
        end

        def field_shell(label_key, hint_key)
          label(style: 'display: grid; gap: 6px;') do
            span(style: label_style) { t_web(label_key) }
            yield
            span(class: 'muted', style: 'font-size: 11px;') { t_web(hint_key) }
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
