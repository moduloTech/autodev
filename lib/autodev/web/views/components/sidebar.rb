# frozen_string_literal: true

module Web
  module Views
    module Components
      # Desktop sidebar nav. Mirrors primitives.jsx::Sidebar.
      # Top: logo + theme toggle + lang switcher.
      # Middle: search-bar placeholder + nav items with optional counts.
      # Bottom: "Nouveau ticket" CTA + user info.
      class Sidebar < Phlex::HTML # rubocop:disable Metrics/ClassLength
        def initialize( # rubocop:disable Lint/MissingSuper
          active:, locale:, request_path:,
          counts: {}, translator: nil
        )
          @active = active.to_s
          @locale = locale
          @request_path = request_path
          @counts = counts
          # Caller passes a t_web-like lambda since the Sidebar isn't a Web::Views::Base.
          @t = translator || ->(key, **) { key.to_s }
        end

        def view_template
          aside(class: 'sidebar', style: aside_style) do
            render_top_row
            render_search
            render_nav_items
            div(style: 'flex: 1;')
            render_cta
            render_user_strip
          end
        end

        private

        def aside_style
          'width: 240px; background: var(--paper); border-right: 1px solid var(--border); ' \
            'padding: 18px 14px; display: flex; flex-direction: column; gap: 4px; ' \
            'flex: 0 0 240px; height: 100vh; position: sticky; top: 0;'
        end

        def render_top_row # rubocop:disable Metrics/MethodLength
          div(style: 'padding: 4px 8px 14px; display: flex; align-items: center; ' \
                     'justify-content: space-between;') do
            render Logo.new(size: 24)
            div(style: 'display: flex; gap: 2px; align-items: center;') do
              render_lang_switcher
              render_theme_toggle
              span(class: 'coming-soon', title: @t.call(:web_coming_soon_tooltip)) do
                render IconButton.new(icon: Icon.new(name: 'bell', size: 15),
                                      label: 'Notifications', size: 28)
              end
            end
          end
        end

        def render_lang_switcher
          span(class: 'muted', style: 'font-size: 10px; padding: 0 4px;') do
            Web::I18nHelpers::AVAILABLE_LOCALES.each_with_index do |lang, idx|
              plain ' ' if idx.positive?
              if lang.to_sym == @locale
                strong { lang.upcase }
              else
                a(href: "/locale/#{lang}?back=#{CGI.escape(@request_path)}") { lang.upcase }
              end
            end
          end
        end

        def render_theme_toggle
          button(type: 'button', class: 'icon-btn', 'data-action' => 'toggle-theme',
                 'aria-label' => @t.call(:web_theme_toggle),
                 style: theme_btn_style) do
            raw safe(SUN_SVG)
            raw safe(MOON_SVG)
          end
        end

        SUN_SVG = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' \
                  'stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" ' \
                  'class="theme-icon theme-icon-sun"><circle cx="12" cy="12" r="4"/>' \
                  '<path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.4 1.4M17.6 17.6 19 19' \
                  'M5 19l1.4-1.4M17.6 6.4 19 5"/></svg>'
        MOON_SVG = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' \
                   'stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" ' \
                   'class="theme-icon theme-icon-moon">' \
                   '<path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg>'
        private_constant :SUN_SVG, :MOON_SVG

        def theme_btn_style
          'width: 28px; height: 28px; padding: 0; border-radius: 8px; color: var(--text-muted); ' \
            'background: transparent; border: 1px solid transparent; ' \
            'display: inline-flex; align-items: center; justify-content: center; cursor: pointer;'
        end

        def render_search
          div(style: 'padding: 4px 6px 10px;') do
            div(class: 'coming-soon', title: @t.call(:web_coming_soon_tooltip),
                style: search_style) do
              render Icon.new(name: 'search', size: 14)
              span { @t.call(:web_sidebar_search) }
              span(style: kbd_style) { '⌘K' }
            end
          end
        end

        def search_style
          'display: flex; align-items: center; gap: 8px; padding: 7px 10px; ' \
            'background: var(--paper-2); border-radius: var(--r-md); ' \
            'color: var(--text-muted); font-size: 13px;'
        end

        def kbd_style
          'margin-left: auto; font-size: 11px; color: var(--text-subtle); ' \
            'border: 1px solid var(--border); padding: 1px 5px; border-radius: 4px;'
        end

        ITEMS = [
          { id: 'dashboard', label_key: :web_nav_dashboard,    icon: 'home',      href: '/' },
          { id: 'issues',    label_key: :web_nav_issues,       icon: 'list',      href: '/issues',
            count_key: :issues },
          { id: 'errors',    label_key: :web_nav_to_watch,     icon: 'alert-tri', href: '/errors',
            count_key: :errors, tone: :err },
          { id: 'chat',      label_key: :web_nav_conversations, icon: 'messages', href: '#',
            count_key: :chat, coming_soon: true },
          { id: 'projects',  label_key: :web_nav_projects, icon: 'folder', href: '#',
            coming_soon: true }
        ].freeze
        private_constant :ITEMS

        def render_nav_items
          ITEMS.each { |item| render_nav_item(item) }
        end

        def render_nav_item(item) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
          is_active = @active == item[:id]
          count = item[:count_key] ? @counts[item[:count_key]] : nil
          klass = item[:coming_soon] ? 'coming-soon' : nil
          attrs = { href: item[:href], style: nav_item_style(is_active), class: klass }
          attrs[:title] = @t.call(:web_coming_soon_tooltip) if item[:coming_soon]
          a(**attrs) do
            render Icon.new(name: item[:icon], size: 16,
                            color: nav_icon_color(is_active, item[:tone]))
            span(style: 'flex: 1;') { @t.call(item[:label_key]) }
            if item[:coming_soon]
              span(class: 'coming-soon-badge') { @t.call(:web_coming_soon) }
            elsif !count.nil?
              render_count_badge(count, is_active, item[:tone])
            end
          end
        end

        def nav_item_style(active)
          bg = active ? 'var(--accent-bg)' : 'transparent'
          color = active ? 'var(--accent-fg)' : 'var(--text)'
          'display: flex; align-items: center; gap: 10px; padding: 8px 10px; ' \
            'border-radius: var(--r-md); font-size: 13px; font-weight: 500; ' \
            "background: #{bg}; color: #{color}; text-decoration: none;"
        end

        def nav_icon_color(active, tone)
          return 'var(--accent-fg)' if active
          return 'var(--err-500)' if tone == :err

          'var(--text-muted)'
        end

        def render_count_badge(count, active, tone) # rubocop:disable Metrics/MethodLength
          bg = if tone == :err
                 'var(--err-bg)'
               else
                 active ? 'var(--accent-bg-strong)' : 'var(--paper-2)'
               end
          color = if tone == :err
                    'var(--err-fg)'
                  else
                    active ? 'var(--accent-fg)' : 'var(--text-muted)'
                  end
          span(style: 'font-size: 11px; font-weight: 600; padding: 1px 7px; ' \
                      "border-radius: var(--r-pill); background: #{bg}; color: #{color};") do
            plain count.to_s
          end
        end

        def render_cta # rubocop:disable Metrics/MethodLength
          div(style: cta_style) do
            div(style: 'display: flex; align-items: center; gap: 6px; font-weight: 600; ' \
                       'color: var(--accent-fg); margin-bottom: 4px;') do
              render Icon.new(name: 'sparkles', size: 14)
              plain ' '
              plain @t.call(:web_sidebar_cta_title)
            end
            div(style: 'color: var(--text-muted); line-height: 1.45; font-size: 12px;') do
              @t.call(:web_sidebar_cta_body)
            end
            div(class: 'coming-soon', title: @t.call(:web_coming_soon_tooltip),
                style: 'margin-top: 10px;') do
              render Button.new(kind: :primary, size: :sm, full: true, href: '#',
                                icon: Icon.new(name: 'plus', size: 13)) { @t.call(:web_sidebar_cta_button) }
            end
          end
        end

        def cta_style
          'padding: 12px; ' \
            'background: linear-gradient(140deg, var(--accent-bg), var(--paper-2)); ' \
            'border: 1px solid var(--accent-bg-strong); border-radius: var(--r-md); ' \
            'font-size: 12px; color: var(--text);'
        end

        def render_user_strip
          div(style: 'display: flex; align-items: center; gap: 10px; padding: 10px 8px; ' \
                     'margin-top: 8px; border-top: 1px solid var(--border);') do
            div(style: avatar_style) { 'A' }
            div(style: 'flex: 1; min-width: 0;') do
              div(style: 'font-size: 13px; font-weight: 500; color: var(--text);') { 'autodev' }
              div(style: 'font-size: 11px; color: var(--text-muted);') do
                @t.call(:web_sidebar_user_role)
              end
            end
          end
        end

        def avatar_style
          'display: inline-flex; align-items: center; justify-content: center; ' \
            'width: 28px; height: 28px; border-radius: 50%; background: var(--accent-solid); ' \
            'color: white; font-size: 11px; font-weight: 600; flex: 0 0 auto;'
        end
      end
    end
  end
end
