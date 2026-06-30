# frozen_string_literal: true

module Web
  module Views
    module Components
      # Desktop sidebar nav. Mirrors primitives.jsx::Sidebar.
      # Top: logo + theme toggle + lang switcher.
      # Middle: search-bar placeholder + nav items with optional counts.
      # Bottom: "Nouveau ticket" CTA + user info.
      class Sidebar < Phlex::HTML # rubocop:disable Metrics/ClassLength
        def initialize( # rubocop:disable Lint/MissingSuper,Metrics/ParameterLists
          active:, locale:, request_path:,
          counts: {}, translator: nil, admin: false,
          current_user_email: nil, csrf_token: nil
        )
          @active = active.to_s
          @locale = locale
          @request_path = request_path
          @counts = counts
          @admin = admin
          @current_user_email = current_user_email
          @csrf_token = csrf_token
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

        # Nav grouped into labelled sections. The first section has no header
        # (label_key: nil); `admin: true` hides the whole section (header +
        # items) from non-admins. Item ids stay stable so `active` highlighting
        # and the count badges are unaffected.
        SECTIONS = [
          { label_key: nil, items: [
            { id: 'dashboard', label_key: :web_nav_dashboard, icon: 'home', href: '/' },
            { id: 'help',      label_key: :web_nav_help,      icon: 'info', href: '/help' }
          ] },
          { label_key: :web_nav_section_autodev, items: [
            { id: 'issues', label_key: :web_nav_issues, icon: 'list', href: '/issues',
              count_key: :issues },
            { id: 'errors', label_key: :web_nav_errors, icon: 'alert-tri', href: '/issues?tab=errors',
              count_key: :errors, tone: :err },
            { id: 'waiting', label_key: :web_tab_waiting, icon: 'messages', href: '/issues?tab=waiting',
              count_key: :waiting, tone: :warn },
            { id: 'delivered_review', label_key: :web_tab_delivered_review, icon: 'alert-tri',
              href: '/issues?tab=delivered_review', count_key: :delivered_review, tone: :warn }
          ] },
          { label_key: :web_nav_section_autospec, items: [
            { id: 'autospec_drafting', label_key: :web_autospec_tab_drafting, icon: 'sparkles',
              href: '/autospec_drafts?tab=drafting', count_key: :autospec_drafting },
            { id: 'autospec_pending', label_key: :web_autospec_tab_pending, icon: 'clock',
              href: '/autospec_drafts?tab=pending', count_key: :autospec_pending },
            { id: 'autospec_to_validate', label_key: :web_autospec_tab_to_validate, icon: 'thumb-up',
              href: '/autospec_drafts?tab=to_validate', count_key: :autospec_to_validate, tone: :warn }
          ] },
          { label_key: :web_nav_section_configuration, items: [
            { id: 'projects', label_key: :web_nav_projects, icon: 'folder', href: '/projects' }
          ] },
          { label_key: :web_nav_section_admin, admin: true, items: [
            { id: 'admin', label_key: :web_nav_admin_users, icon: 'users', href: '/admin/users' },
            { id: 'admin_health', label_key: :web_nav_admin_health, icon: 'bell', href: '/admin/health' },
            { id: 'jobs', label_key: :web_nav_admin_jobs, icon: 'settings', href: '/admin/jobs' },
            { id: 'admin_help', label_key: :web_nav_admin_help, icon: 'info', href: '/admin/help' }
          ] }
        ].freeze
        private_constant :SECTIONS

        def render_nav_items
          visible = SECTIONS.reject { |section| section[:admin] && !@admin }
          visible.each_with_index do |section, idx|
            render_section_separator unless idx.zero?
            render_section_label(section[:label_key]) if section[:label_key]
            section[:items].each { |item| render_nav_item(item) }
          end
        end

        def render_section_separator
          div(style: 'height: 1px; background: var(--border); margin: 10px 6px 2px;')
        end

        def render_section_label(label_key)
          div(style: 'font-size: 10px; font-weight: 600; letter-spacing: 0.06em; ' \
                     'text-transform: uppercase; color: var(--text-muted); padding: 2px 8px 2px;') do
            @t.call(label_key)
          end
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
          return 'var(--warn-500)' if tone == :warn

          'var(--text-muted)'
        end

        def render_count_badge(count, active, tone)
          bg = count_badge_bg(active, tone)
          color = count_badge_color(active, tone)
          span(style: 'font-size: 11px; font-weight: 600; padding: 1px 7px; ' \
                      "border-radius: var(--r-pill); background: #{bg}; color: #{color};") do
            plain count.to_s
          end
        end

        def count_badge_bg(active, tone)
          return 'var(--err-bg)' if tone == :err
          return 'var(--warn-bg)' if tone == :warn

          active ? 'var(--accent-bg-strong)' : 'var(--paper-2)'
        end

        def count_badge_color(active, tone)
          return 'var(--err-fg)' if tone == :err
          return 'var(--warn-fg)' if tone == :warn

          active ? 'var(--accent-fg)' : 'var(--text-muted)'
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
            div(style: 'margin-top: 10px;') do
              render Button.new(kind: :primary, size: :sm, full: true,
                                href: '/autospec_drafts/new',
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
          username = user_display_name
          div(style: user_strip_style) do
            div(style: avatar_style) { username[0, 1].upcase }
            div(style: 'flex: 1; min-width: 0;') do
              div(style: username_style) { username }
              render_signout_link
            end
          end
        end

        def user_strip_style
          'display: flex; align-items: center; gap: 10px; padding: 10px 8px; ' \
            'margin-top: 8px; border-top: 1px solid var(--border);'
        end

        def username_style
          'font-size: 13px; font-weight: 500; color: var(--text); ' \
            'overflow: hidden; text-overflow: ellipsis; white-space: nowrap;'
        end

        def user_display_name
          local = @current_user_email.to_s.split('@', 2).first.to_s
          local.empty? ? 'autodev' : local
        end

        def render_signout_link
          form(action: '/users/sign_out', method: 'post',
               'data-turbo' => 'false', style: 'display: inline;') do
            input(type: 'hidden', name: '_method', value: 'delete')
            input(type: 'hidden', name: 'authenticity_token', value: @csrf_token) if @csrf_token.present?
            button(type: 'submit', style: signout_btn_style) { @t.call(:web_sign_out) }
          end
        end

        def signout_btn_style
          'background: none; border: 0; padding: 0; cursor: pointer; ' \
            'font-size: 11px; color: var(--text-muted); text-align: left;'
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
