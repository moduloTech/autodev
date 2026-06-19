# frozen_string_literal: true

module Web
  module Views
    # Generic shell for the in-app help pages: sidebar + topbar + rendered
    # markdown article. Used by both `/help` (functional doc, open to all
    # signed-in users) and `/admin/help` (technical doc, admin-gated).
    # The caller passes `content` (pre-rendered HTML from `HelpDoc`), the
    # `active` sidebar key to highlight, and the locale keys for the
    # topbar title + subtitle.
    class Help < Base
      TOC_NAV_STYLE = 'margin-bottom: 24px; padding: 16px 20px; max-width: 720px; ' \
                      'background: var(--paper-2); border: 1px solid var(--border); ' \
                      'border-radius: var(--r-md);'
      TOC_TITLE_STYLE = 'font-weight: 600; font-size: 13px; color: var(--text-muted); ' \
                        'text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 10px;'

      def initialize(content:, active:, title_key:, subtitle_key:, **opts)
        @label_selector = opts.delete(:label_selector)
        @toc = opts.delete(:toc)
        super(**opts)
        @content = content
        @active = active
        @title_key = title_key
        @subtitle_key = subtitle_key
      end

      def view_template
        with_layout(nav: false, shell: false) do
          div(class: 'app-shell') do
            render_sidebar
            main { render_main }
          end
        end
      end

      def render_main
        render_topbar
        div(class: 'help-doc-content', style: 'flex: 1; overflow: auto; padding: 28px 40px;') do
          render_label_selector
          render_toc
          article(class: 'help-doc') { raw safe(@content) }
        end
      end

      private

      # Table of contents (built by HelpDoc from the rendered headings).
      # Shown above the article on both help pages.
      def render_toc
        return if @toc.nil? || @toc.to_s.empty?

        nav(class: 'help-toc', style: TOC_NAV_STYLE) do
          div(style: TOC_TITLE_STYLE) { plain t_web(:web_help_toc_title) }
          raw safe(@toc)
        end
      end

      # Shown only when the user's visible projects use differing label sets
      # (`HelpController` passes a `label_selector` payload). A GET form that
      # re-renders the guide with the chosen project's label names; submits
      # on change so there's no extra button.
      def render_label_selector
        return unless @label_selector

        form(method: 'get', action: '/help', class: 'help-project-picker', style: 'margin-bottom: 20px;') do
          label(style: 'margin-right: 8px;') { plain t_web(:web_help_project_selector) }
          select(name: 'project') do
            @label_selector[:projects].each { |p| render_label_option(p) }
          end
          button(type: 'submit', class: 'btn btn-primary-sm', style: 'margin-left: 8px;') do
            plain t_web(:web_help_project_apply)
          end
        end
      end

      def render_label_option(proj)
        attrs = { value: proj[:path] }
        attrs[:selected] = true if proj[:path] == @label_selector[:selected]
        option(**attrs) { plain "#{proj[:path]} (#{proj[:todo]})" }
      end

      def render_sidebar
        render Components::Sidebar.new(
          active: @active, locale: web_locale, request_path: @request_path,
          counts: {}, translator: ->(key, **vars) { t_web(key, **vars) },
          admin: @current_user_admin,
          current_user_email: @current_user_email, csrf_token: @csrf_token
        )
      end

      # Both help pages show the running Autodev version in the topbar's
      # right-hand slot. "Autodev v<x>" is a technical token (brand + version),
      # so it is not localized.
      def render_topbar
        render Components::Topbar.new(
          title: t_web(@title_key),
          subtitle: t_web(@subtitle_key)
        ) do
          span(style: 'font-size: 12px; color: var(--text-muted); white-space: nowrap;') do
            plain "Autodev v#{::Autodev::VERSION}"
          end
        end
      end
    end
  end
end
