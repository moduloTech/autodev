# frozen_string_literal: true

module Web
  module Views
    # Wraps page content with the shared HTML head, nav, and locale switcher.
    class Layout < Phlex::HTML
      include Web::I18nHelpers

      CSS = <<~CSS
        :root { color-scheme: light dark; }
        body { font-family: ui-sans-serif, system-ui, sans-serif; max-width: 1100px; margin: 1.5rem auto; padding: 0 1rem; }
        nav a { margin-right: 1rem; }
        h1 { font-size: 1.4rem; margin: 0 0 1rem; }
        h2 { font-size: 1.1rem; margin-top: 1.5rem; }
        table { border-collapse: collapse; width: 100%; font-size: 0.9rem; }
        th, td { border-bottom: 1px solid #8884; padding: 0.35rem 0.5rem; text-align: left; vertical-align: top; }
        .badge { display: inline-block; padding: 0.05rem 0.5rem; border-radius: 0.5rem; font-size: 0.8rem; }
        .badge-active { background: #08f3; }
        .badge-error { background: #f444; }
        .badge-done { background: #0a73; }
        .badge-pending { background: #fc04; }
        .muted { opacity: 0.7; }
        code, pre { font-family: ui-monospace, monospace; }
        pre { background: #8881; padding: 0.5rem; overflow-x: auto; }
        button { font: inherit; padding: 0.3rem 0.7rem; cursor: pointer; }
      CSS

      SSE_PUMP_JS = <<~JS
        document.addEventListener('turbo:load', () => {
          if (window.__autodevSSE) return;
          const es = new EventSource('/stream');
          es.onmessage = (e) => Turbo.renderStreamMessage(e.data);
          window.__autodevSSE = es;
        });
        // Generic confirm-on-submit: forms can opt in via data-confirm="..."
        // or data-confirm-template="...$event..." (interpolates select[name=event].value).
        document.addEventListener('submit', (e) => {
          const f = e.target;
          let msg = f.getAttribute('data-confirm');
          if (!msg) {
            const tpl = f.getAttribute('data-confirm-template');
            if (tpl) {
              const sel = f.querySelector('select[name=event]');
              msg = tpl.replace('$event', sel ? sel.value : '');
            }
          }
          if (msg && !confirm(msg)) e.preventDefault();
        });
      JS

      def initialize(locale: :fr, request_path: '/') # rubocop:disable Lint/MissingSuper
        @locale = locale
        @request_path = request_path
      end

      def web_locale
        @locale
      end

      def view_template(&) # rubocop:disable Metrics/MethodLength
        doctype
        html(lang: @locale.to_s) do
          head do
            meta(charset: 'utf-8')
            title { 'autodev' }
            style { raw(safe(CSS)) }
            script(src: '/assets/turbo.js', defer: true)
            script { raw(safe(SSE_PUMP_JS)) }
          end
          body do
            render_nav
            yield
          end
        end
      end

      private

      def render_nav
        nav(style: 'display: flex; justify-content: space-between; align-items: baseline') do
          span do
            a(href: '/') { t_web(:web_nav_dashboard) }
            plain ' '
            a(href: '/errors') { t_web(:web_nav_errors) }
            plain ' '
            a(href: '/issues') { t_web(:web_nav_all_issues) }
          end
          render_lang_switcher
        end
      end

      def render_lang_switcher
        span(class: 'muted', style: 'font-size: 0.85rem') do
          Web::I18nHelpers::AVAILABLE_LOCALES.each_with_index do |lang, idx|
            plain ' ' if idx.positive?
            if lang.to_sym == web_locale
              strong { lang.upcase }
            else
              a(href: "/locale/#{lang}?back=#{CGI.escape(@request_path)}") { lang.upcase }
            end
          end
        end
      end
    end
  end
end
