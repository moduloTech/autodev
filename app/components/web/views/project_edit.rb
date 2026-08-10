# frozen_string_literal: true

module Web
  module Views
    # GET /projects/:slug/edit — per-project config edit form (task #9 phase 3).
    #
    # Renders one input per editable config column, grouped into Basic /
    # Execution / Advanced sections, and PATCHes /projects/:slug. The field
    # labels are the raw config-key names (technical tokens, identical in both
    # locales and the same names the operator used in config.yml) shown as
    # <code>; only the surrounding chrome (section titles, hints, buttons,
    # error banner) goes through t_web. Values come straight off the record, so
    # a failed #update (which assigned-but-didn't-save) re-renders the
    # submitted values plus the validation errors.
    class ProjectEdit < Base # rubocop:disable Metrics/ClassLength
      # Editable config fields grouped into the form's sections. Each entry is
      # [section title key, [config keys]]; #render_field picks the input type
      # per key from the Project::CONFIG_* groupings.
      SECTIONS = [
        [:web_project_edit_section_basic,
         %i[target_branch labels_todo label_doing label_done extra_prompt]],
        [:web_project_edit_section_execution,
         %i[dc_timeout max_retries retry_backoff stagnation_threshold clone_depth
            sparse_checkout post_completion post_completion_timeout mr_review_timeout]],
        [:web_project_edit_section_advanced,
         %i[model effort parallel_agents split_implementation implementer_agent
            test_writer_agent mr_fixer_agent]]
      ].freeze
      private_constant :SECTIONS

      # The baked global default (Config::DEFAULTS / documented in
      # Config::TEMPLATE) shown in each field's hint as "Défaut : <value>", so
      # the operator knows what an empty field falls back to. Fields without a
      # fixed value (target_branch, labels, prompts, agents) get a descriptive
      # hint via HINT_KEYS instead.
      DEFAULT_HINT_VALUES = {
        dc_timeout: 1800, max_retries: 1, retry_backoff: 10, stagnation_threshold: 5,
        clone_depth: 1, post_completion_timeout: 300, mr_review_timeout: 3600,
        parallel_agents: 'false', split_implementation: 'false'
      }.freeze
      private_constant :DEFAULT_HINT_VALUES

      def initialize(project:, **)
        super(**)
        @project = project
      end

      def view_template
        with_layout(nav: false, shell: false) do
          div(class: 'app-shell') do
            render_sidebar
            render_main
          end
        end
      end

      private

      def render_main
        main do
          render_topbar
          div(style: 'flex: 1; overflow: auto; padding: 28px;') do
            render_error_banner if @project.errors.any?
            render_columns
          end
        end
      end

      def render_columns
        div(class: 'project-edit-layout',
            style: 'display: grid; grid-template-columns: minmax(0, 1fr) minmax(260px, 320px); ' \
                   'gap: 24px; align-items: start; max-width: 1120px;') do
          render_form
          render_help_panel
        end
      end

      # Right-hand guidance column (the form's left). Explains the
      # project > global > baked-default precedence, what an empty field does,
      # and the list/boolean conventions — the per-field defaults themselves
      # live in each field's inline hint.
      def render_help_panel
        div(style: 'position: sticky; top: 0; display: grid; gap: 16px;') do
          render(Components::Card.new(padding: 20)) do
            h3(class: 'sidecard-title', style: 'margin: 0 0 12px;') { t_web(:web_project_edit_help_title) }
            render_help_items
            render_help_link if @current_user_admin
          end
          render_templates_card unless @project.new_record?
        end
      end

      # Entry point to the per-project ticket templates (task #14) — the
      # structure AutoSpec follows when drafting on this project. Same
      # editor gate as this config form, so the link is safe to show here.
      def render_templates_card
        render(Components::Card.new(padding: 20)) do
          h3(class: 'sidecard-title', style: 'margin: 0 0 8px;') { t_web(:web_ticket_templates_title_short) }
          p(class: 'muted', style: 'margin: 0 0 12px; font-size: 12px; line-height: 1.5;') do
            t_web(:web_ticket_templates_card_hint)
          end
          a(href: "/projects/#{@project.slug}/ticket_templates", class: 'button',
            style: 'padding: 7px 12px; font-size: 12px;') do
            t_web(:web_ticket_templates_manage)
          end
        end
      end

      def render_help_items
        ul(style: 'margin: 0; padding-left: 18px; display: grid; gap: 10px; ' \
                  'font-size: 12px; color: var(--text-muted); line-height: 1.5;') do
          %i[precedence blank lists booleans].each do |k|
            li { t_web(:"web_project_edit_help_#{k}") }
          end
        end
      end

      def render_help_link
        p(style: 'margin: 14px 0 0; font-size: 12px;') do
          a(href: '/admin/help', style: 'color: var(--accent-solid);') { t_web(:web_project_edit_help_link) }
        end
      end

      def render_sidebar
        render Components::Sidebar.new(
          active: 'projects', locale: web_locale, request_path: @request_path,
          counts: {}, admin: @current_user_admin,
          translator: ->(key, **vars) { t_web(key, **vars) },
          current_user_email: @current_user_email, csrf_token: @csrf_token
        )
      end

      def render_topbar
        render(Components::Topbar.new(**topbar_args))
      end

      def topbar_args
        root = t_web(:web_project_breadcrumb_root)
        if @project.new_record?
          { title: t_web(:web_project_new_title), subtitle: t_web(:web_project_new_subtitle),
            breadcrumb: "#{root} › #{t_web(:web_project_new_title)}" }
        else
          { title: t_web(:web_project_edit_title, path: @project.gitlab_path),
            subtitle: t_web(:web_project_edit_subtitle), breadcrumb: "#{root} › #{@project.gitlab_path}" }
        end
      end

      def render_error_banner
        div(class: 'error-banner',
            style: 'background: var(--err-bg); border: 1px solid var(--err-fg); ' \
                   'border-radius: var(--r-md); padding: 12px 14px; margin-bottom: 18px;') do
          p(style: 'margin: 0 0 6px; font-weight: 600; color: var(--err-fg); font-size: 13px;') do
            t_web(:web_project_edit_error_banner)
          end
          ul(style: 'margin: 0; padding-left: 18px; font-size: 12px; color: var(--err-fg);') do
            @project.errors.full_messages.each { |msg| li { plain msg } }
          end
        end
      end

      def render_form
        form(action: form_action, method: 'post', style: 'display: grid; gap: 22px;') do
          csrf_input_tag
          input(type: 'hidden', name: '_method', value: 'patch') unless @project.new_record?
          render_identity_section if @project.new_record?
          SECTIONS.each { |title_key, keys| render_section(title_key, keys) }
          render_submit_row
        end
      end

      def form_action
        @project.new_record? ? '/projects' : "/projects/#{@project.slug}"
      end

      # Identity fields (new projects only): gitlab_path drives the slug + name,
      # default_locale the per-issue language. Not config columns, so they're
      # rendered here rather than via SECTIONS / render_field.
      def render_identity_section
        render(Components::Card.new(padding: 24)) do
          h3(class: 'sidecard-title', style: 'margin: 0 0 16px;') { t_web(:web_project_new_section_identity) }
          div(style: 'display: grid; gap: 16px;') do
            render_identity_path
            render_identity_locale
          end
        end
      end

      def render_identity_path
        label(style: 'display: grid; gap: 6px;') do
          span(style: field_label_style) { code { 'gitlab_path' } }
          input(type: 'text', name: 'gitlab_path', value: @project.gitlab_path.to_s, required: true,
                placeholder: 'group/sous-groupe/projet', style: input_style)
          span(class: 'muted', style: 'font-size: 11px;') { t_web(:web_project_new_desc_gitlab_path) }
        end
      end

      def render_identity_locale
        current = @project.default_locale.presence || 'fr'
        label(style: 'display: grid; gap: 6px;') do
          span(style: field_label_style) { code { 'default_locale' } }
          select(name: 'default_locale', style: input_style) do
            %w[fr en].each { |loc| locale_option(loc, current) }
          end
          span(class: 'muted', style: 'font-size: 11px;') { t_web(:web_project_new_desc_default_locale) }
        end
      end

      def locale_option(loc, current)
        opts = { value: loc }
        opts[:selected] = true if loc == current
        option(**opts) { loc }
      end

      def render_section(title_key, keys)
        render(Components::Card.new(padding: 24)) do
          h3(class: 'sidecard-title', style: 'margin: 0 0 16px;') { t_web(title_key) }
          div(style: 'display: grid; gap: 16px;') do
            keys.each { |key| render_field(key) }
          end
        end
      end

      def render_field(key)
        return render_array_field(key)   if Project::LIST_CONFIG_KEYS.include?(key)
        return render_boolean_field(key) if Project::BOOLEAN_CONFIG_FIELDS.include?(key)
        return render_integer_field(key) if Project::CONFIG_INTEGER_FIELDS.include?(key)
        return render_text_field(key)    if key == :extra_prompt

        render_string_field(key)
      end

      def render_string_field(key)
        field_shell(key) do
          input(type: 'text', name: key.to_s, value: @project.public_send(key).to_s, style: input_style)
        end
      end

      def render_text_field(key)
        field_shell(key) do
          textarea(name: key.to_s, rows: '4',
                   style: "#{input_style} font-family: var(--font-mono); font-size: 13px;") do
            plain @project.public_send(key).to_s
          end
        end
      end

      def render_integer_field(key)
        field_shell(key) do
          input(type: 'number', name: key.to_s, value: @project.public_send(key)&.to_s,
                min: key == :clone_depth ? '0' : '1', style: input_style)
        end
      end

      def render_array_field(key)
        field_shell(key) do
          textarea(name: key.to_s, rows: '3',
                   style: "#{input_style} font-family: var(--font-mono); font-size: 13px;") do
            plain Array(@project.public_send(key)).join("\n")
          end
        end
      end

      def render_boolean_field(key)
        current = @project.public_send(key)
        field_shell(key) do
          select(name: key.to_s, style: input_style) do
            bool_option('', current.nil?, :web_project_edit_bool_default)
            bool_option('true', current == true, :web_project_edit_bool_true)
            bool_option('false', current == false, :web_project_edit_bool_false)
          end
        end
      end

      def bool_option(value, selected, label_key)
        opts = { value: value }
        opts[:selected] = true if selected
        option(**opts) { t_web(label_key) }
      end

      def field_shell(key)
        label(style: 'display: grid; gap: 6px;') do
          span(style: field_label_style) { code { key.to_s } }
          yield
          span(class: 'muted', style: 'font-size: 11px;') { field_hint(key) }
        end
      end

      # The inline hint under a field: a one-line description of what the
      # option does (web_project_edit_desc_<key>), with the baked global
      # default appended ("Défaut : N") for the fields that have a fixed one
      # (the rest state their default inline in the description text).
      def field_hint(key)
        desc = t_web(:"web_project_edit_desc_#{key}")
        return desc unless DEFAULT_HINT_VALUES.key?(key)

        "#{desc} #{t_web(:web_project_edit_default, value: DEFAULT_HINT_VALUES[key])}"
      end

      def render_submit_row
        cancel_href = @project.new_record? ? '/projects' : "/projects/#{@project.slug}?tab=config"
        save_key = @project.new_record? ? :web_project_new_create : :web_project_edit_save
        div(style: 'display: flex; justify-content: flex-end; gap: 10px;') do
          a(href: cancel_href, class: 'button', style: 'padding: 8px 14px; font-size: 13px;') do
            t_web(:web_project_edit_cancel)
          end
          render Components::Button.new(kind: :primary, size: :md, type: 'submit') do
            t_web(save_key)
          end
        end
      end

      def field_label_style
        'font-size: 13px; font-weight: 600; color: var(--text); font-family: var(--font-mono);'
      end

      def input_style
        'background: var(--paper-2); border: 1px solid var(--border); ' \
          'border-radius: var(--r-md); padding: 9px 12px; font-size: 13px; ' \
          'color: var(--text); width: 100%; box-sizing: border-box;'
      end
    end
  end
end
