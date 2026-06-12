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
      def initialize(content:, active:, title_key:, subtitle_key:, **)
        super(**)
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
          article(class: 'help-doc') { raw safe(@content) }
        end
      end

      private

      def render_sidebar
        render Components::Sidebar.new(
          active: @active, locale: web_locale, request_path: @request_path,
          counts: {}, translator: ->(key, **vars) { t_web(key, **vars) },
          admin: @current_user_admin,
          current_user_email: @current_user_email, csrf_token: @csrf_token
        )
      end

      def render_topbar
        render Components::Topbar.new(
          title: t_web(@title_key),
          subtitle: t_web(@subtitle_key)
        )
      end
    end
  end
end
