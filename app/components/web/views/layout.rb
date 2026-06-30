# frozen_string_literal: true

module Web
  module Views
    # Wraps page content with the shared HTML head, nav, and locale switcher.
    class Layout < Phlex::HTML # rubocop:disable Metrics/ClassLength
      include Web::I18nHelpers

      # Reads localStorage and applies data-theme on <html> BEFORE the body
      # paints, to avoid a flash of the wrong theme. Must run synchronously
      # in <head> — no defer, no DOMContentLoaded.
      THEME_BOOTSTRAP_JS = <<~JS
        (function () {
          try {
            var t = localStorage.getItem('autodev-theme');
            if (t === 'light' || t === 'dark') {
              document.documentElement.dataset.theme = t;
            } else {
              document.documentElement.dataset.theme =
                window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
            }
          } catch (e) { /* localStorage unavailable, fall back to CSS default */ }
        })();
      JS

      APP_JS = <<~JS
        // SSE → Turbo Stream pump. Skipped under browser automation because
        // /stream is a long-lived ActionController::Live response and counts
        // as a permanently in-flight request: any caller that waits on
        // `networkidle` (Chrome DevTools MCP's navigate_page, Puppeteer's
        // default waitUntil, etc.) would hang until its own timeout.
        // The dashboard is still fully usable from automation — only the
        // live-update channel is dropped; page reloads still surface fresh data.
        document.addEventListener('turbo:load', () => {
          if (window.__autodevSSE) return;
          if (navigator.webdriver) return;
          const es = new EventSource('/stream');
          es.onmessage = (e) => Turbo.renderStreamMessage(e.data);
          window.__autodevSSE = es;
        });

        // Close the EventSource proactively on `pagehide` (F5, tab close,
        // cross-document navigation). Without this, the browser tears down
        // the client-side socket but the server's StreamController stays
        // parked on Queue#pop until the next heartbeat tick detects the
        // dead TCP via a write — up to HEARTBEAT_INTERVAL seconds of
        // Puma-thread squat per stale connection. With enough refreshes
        // / concurrent tabs, the pool saturates and every Rails request
        // freezes. Closing client-side sends a FIN immediately so the
        // server's next write raises ClientDisconnected and the thread
        // is released right away. See autospec.md §L for the full story.
        window.addEventListener('pagehide', () => {
          if (window.__autodevSSE) {
            window.__autodevSSE.close();
            window.__autodevSSE = null;
          }
        });

        // Delegated confirm-on-submit (Phlex 2 forbids inline onsubmit).
        // Native <dialog> instead of window.confirm so the prompt stays
        // styled with the app and supports keyboard/screenreader navigation.
        document.addEventListener('submit', (e) => {
          const f = e.target;
          if (f.id === 'confirm-dialog-form') return;
          let msg = f.getAttribute('data-confirm');
          if (!msg) {
            const tpl = f.getAttribute('data-confirm-template');
            if (tpl) {
              const sel = f.querySelector('select[name=event]');
              const opt = sel && sel.options[sel.selectedIndex];
              msg = tpl.replace('$event', opt ? opt.text : (sel ? sel.value : ''));
            }
          }
          if (!msg) return;
          e.preventDefault();
          const dialog = document.getElementById('confirm-dialog');
          if (!dialog || !dialog.showModal) {
            // Browser without <dialog> support — fall back to confirm().
            if (confirm(msg)) f.submit();
            return;
          }
          dialog.querySelector('.confirm-dialog-message').textContent = msg;
          dialog.returnValue = '';
          dialog.showModal();
          // form.submit() does NOT re-fire the submit event, so no recursion.
          dialog.addEventListener('close', () => {
            if (dialog.returnValue === 'confirm') f.submit();
          }, { once: true });
        });

        // Theme toggle — wired via data-action="toggle-theme".
        document.addEventListener('click', (e) => {
          const btn = e.target.closest('[data-action="toggle-theme"]');
          if (!btn) return;
          const next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
          document.documentElement.dataset.theme = next;
          try { localStorage.setItem('autodev-theme', next); } catch (_) {}
          btn.setAttribute('aria-pressed', next === 'dark');
        });
      JS

      def initialize(locale: :fr, request_path: '/', nav: true, shell: true, # rubocop:disable Lint/MissingSuper,Metrics/ParameterLists
                     csrf_token: nil, flash: {})
        @locale = locale
        @request_path = request_path
        @nav = nav
        @shell = shell
        @csrf_token = csrf_token
        @flash = flash || {}
      end

      def web_locale
        @locale
      end

      def view_template(&) # rubocop:disable Metrics/MethodLength
        doctype
        html(lang: @locale.to_s) do
          render_head
          body do
            render_flash_banner
            if @shell
              div(class: 'page-shell') do
                render_nav if @nav
                yield
              end
            else
              yield
            end
            render_confirm_dialog
          end
        end
      end

      FLASH_BANNER_BASE = 'position: fixed; top: 16px; left: 50%; transform: translateX(-50%); ' \
                          'z-index: 1000; max-width: min(560px, calc(100vw - 32px)); ' \
                          'padding: 10px 16px; border-radius: var(--r-md); font-size: 13px; ' \
                          'box-shadow: var(--shadow-md, 0 4px 16px rgba(0,0,0,0.12));'
      FLASH_TONES = {
        notice: 'background: var(--ok-500); color: white; border: 1px solid var(--ok-700);',
        alert: 'background: var(--err-500); color: white; border: 1px solid var(--err-700);'
      }.freeze

      # Transient feedback banner for redirect-then-flash actions (e.g. the
      # review-env redeploy). Auto-dismisses after a few seconds; rendered
      # once at the top of <body> so it floats above any page chrome.
      def render_flash_banner
        tone, message = flash_tone_and_message
        return unless message

        div(class: 'flash-banner', role: 'status',
            style: "#{FLASH_BANNER_BASE} #{FLASH_TONES.fetch(tone)}") { plain message }
        script { raw(safe(FLASH_DISMISS_JS)) }
      end

      FLASH_DISMISS_JS = <<~JS
        setTimeout(function () {
          document.querySelectorAll('.flash-banner').forEach(function (n) { n.remove(); });
        }, 5000);
      JS

      def flash_tone_and_message
        return [:notice, @flash[:notice]] if @flash[:notice].present?
        return [:alert, @flash[:alert]] if @flash[:alert].present?

        [nil, nil]
      end

      def render_confirm_dialog # rubocop:disable Metrics/MethodLength
        dialog(id: 'confirm-dialog', class: 'confirm-dialog') do
          form(id: 'confirm-dialog-form', method: 'dialog') do
            h2(class: 'confirm-dialog-title') { t_web(:web_confirm_title) }
            p(class: 'confirm-dialog-message')
            div(class: 'confirm-dialog-actions') do
              button(type: 'submit', value: 'cancel',
                     class: 'confirm-dialog-btn confirm-dialog-btn-secondary') do
                t_web(:web_confirm_cancel)
              end
              button(type: 'submit', value: 'confirm',
                     class: 'confirm-dialog-btn confirm-dialog-btn-primary') do
                t_web(:web_confirm_ok)
              end
            end
          end
        end
      end

      THEME_BTN_STYLE = 'width: 30px; height: 30px; border-radius: var(--r-sm); ' \
                        'display: inline-flex; align-items: center; justify-content: center; ' \
                        'border: 1px solid var(--border); background: var(--paper);'

      SVG_ATTRS = 'width="16" height="16" viewBox="0 0 24 24" fill="none" ' \
                  'stroke="currentColor" stroke-width="1.6" ' \
                  'stroke-linecap="round" stroke-linejoin="round"'

      SUN_ICON_SVG = <<~SVG.freeze
        <svg #{SVG_ATTRS} class="theme-icon theme-icon-sun">
          <circle cx="12" cy="12" r="4"/>
          <path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.4 1.4M17.6 17.6 19 19M5 19l1.4-1.4M17.6 6.4 19 5"/>
        </svg>
      SVG

      MOON_ICON_SVG = <<~SVG.freeze
        <svg #{SVG_ATTRS} class="theme-icon theme-icon-moon">
          <path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/>
        </svg>
      SVG

      private

      def render_head # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
        head do
          meta(charset: 'utf-8')
          meta(name: 'viewport', content: 'width=device-width, initial-scale=1')
          # CSRF token meta tags — Turbo + any fetch() in APP_JS picks them up
          # automatically and sends them on non-GET requests. Phlex forms also
          # emit the same value via csrf_input_tag.
          if @csrf_token.present?
            meta(name: 'csrf-param', content: 'authenticity_token')
            meta(name: 'csrf-token', content: @csrf_token)
          end
          title { 'autodev' }
          # Theme bootstrap MUST come before stylesheets to avoid FOUC.
          script { raw(safe(THEME_BOOTSTRAP_JS)) }
          link(rel: 'stylesheet', href: '/assets/css/tokens.css')
          link(rel: 'stylesheet', href: '/assets/css/fonts.css')
          link(rel: 'stylesheet', href: '/assets/css/app.css')
          script(src: '/assets/turbo.js', defer: true)
          script { raw(safe(APP_JS)) }
        end
      end

      def render_nav
        nav(style: 'display: flex; justify-content: space-between; align-items: center; gap: 1rem;') do
          span { render_nav_links }
          span(style: 'display: flex; align-items: center; gap: 0.6rem;') do
            render_lang_switcher
            render_theme_toggle
          end
        end
      end

      def render_nav_links
        a(href: '/') { t_web(:web_nav_dashboard) }
        plain ' '
        a(href: '/issues?tab=errors') { t_web(:web_nav_errors) }
        plain ' '
        a(href: '/issues') { t_web(:web_nav_all_issues) }
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

      def render_theme_toggle
        button(type: 'button', class: 'icon-btn', 'data-action' => 'toggle-theme',
               'aria-label' => t_web(:web_theme_toggle), style: THEME_BTN_STYLE) do
          # Both icons rendered; CSS hides the inactive one via data-theme.
          raw safe(SUN_ICON_SVG)
          raw safe(MOON_ICON_SVG)
        end
      end
    end
  end
end
