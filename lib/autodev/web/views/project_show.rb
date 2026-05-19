# frozen_string_literal: true

module Web
  module Views
    # GET /projects/:slug — sidebar + topbar + tabs (overview / requests
    # / config / team). Mirrors design/screen-project.jsx.
    class ProjectShow < Base # rubocop:disable Metrics/ClassLength
      TABS = %w[overview issues config team].freeze
      private_constant :TABS

      # rubocop:disable Metrics/ParameterLists
      def initialize(project_path:, project_config:, project_issues:,
                     stats:, kpis:, tab:, **)
        super(**)
        @project_path = project_path
        @project_config = project_config
        @project_issues = project_issues
        @stats = stats
        @kpis = kpis
        @tab = TABS.include?(tab) ? tab : 'overview'
      end
      # rubocop:enable Metrics/ParameterLists

      def view_template # rubocop:disable Metrics/MethodLength
        with_layout(nav: false, shell: false) do
          div(class: 'app-shell') do
            render_sidebar
            main do
              render_topbar
              render_tab_bar
              div(class: 'project-content', style: 'flex: 1; overflow: auto; padding: 28px;') do
                render_active_tab
              end
            end
          end
        end
      end

      private

      def render_sidebar
        render Components::Sidebar.new(
          active: 'projects', locale: web_locale, request_path: @request_path,
          counts: { issues: @kpis[:active], errors: @kpis[:errors], chat: 0 },
          translator: ->(key, **vars) { t_web(key, **vars) }
        )
      end

      def render_topbar # rubocop:disable Metrics/MethodLength
        render(Components::Topbar.new(
                 title: @project_path,
                 subtitle: project_description,
                 breadcrumb: "#{t_web(:web_project_breadcrumb_root)} › #{@project_path}"
               )) do
          if (url = gitlab_project_url(@project_path))
            render Components::Button.new(kind: :secondary, size: :md, href: url,
                                          icon: Components::Icon.new(name: 'external', size: 14)) do
              t_web(:web_project_view_on_gitlab)
            end
          end
          span(class: 'coming-soon', title: t_web(:web_coming_soon_tooltip)) do
            render Components::Button.new(kind: :primary, size: :md, href: '#',
                                          icon: Components::Icon.new(name: 'plus', size: 14)) do
              t_web(:web_dashboard_new_request)
            end
          end
        end
      end

      def project_description
        @project_config['extra_prompt'] || t_web(:web_project_no_description)
      end

      TAB_DEFS = [
        { id: 'overview', label_key: :web_project_tab_overview },
        { id: 'issues',   label_key: :web_project_tab_issues, count_attr: :total },
        { id: 'config',   label_key: :web_project_tab_config },
        { id: 'team',     label_key: :web_project_tab_team }
      ].freeze
      private_constant :TAB_DEFS

      def render_tab_bar
        slug = project_slug(@project_path)
        div(class: 'project-tabs') do
          TAB_DEFS.each { |tab| render_project_tab(tab, slug) }
        end
      end

      def render_project_tab(tab, slug)
        is_active = @tab == tab[:id]
        a(href: "/projects/#{slug}?tab=#{tab[:id]}",
          class: is_active ? 'project-tab project-tab-active' : 'project-tab') do
          plain t_web(tab[:label_key])
          if tab[:count_attr] && (count = @stats[tab[:count_attr]])
            plain ' '
            span(class: 'project-tab-count') { plain count.to_s }
          end
        end
      end

      def render_active_tab
        case @tab
        when 'issues' then render_issues_tab
        when 'config' then render_config_tab
        when 'team'   then render_team_tab
        else render_overview_tab
        end
      end

      # === Overview tab ====================================================

      def render_overview_tab
        div(class: 'project-overview-grid') do
          div(style: 'display: flex; flex-direction: column; gap: 22px;') do
            render_hero_card
            render_recent_card
          end
          div(style: 'display: flex; flex-direction: column; gap: 22px;') do
            render_technical_card
            render_team_preview_card
          end
        end
      end

      def render_hero_card # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
        render(Components::Card.new(padding: 0)) do
          div(class: 'hero-band',
              style: "background: linear-gradient(135deg, #{project_dot_color(@project_path)}22, var(--paper) 75%);") do
            div(class: 'hero-row') do
              span(class: 'hero-mark', style: "background: #{project_dot_color(@project_path)};") do
                plain @project_path[0].upcase
              end
              div do
                div(class: 'hero-name') { @project_path }
                div(class: 'hero-repo') { gitlab_project_url(@project_path) || @project_path }
              end
            end
            p(class: 'hero-description') { project_description }
          end
          div(class: 'project-stats-grid') do
            render_stat(:web_project_stat_active,     @stats[:active],     :working)
            render_stat(:web_project_stat_errors,     @stats[:errors],     :err)
            render_stat(:web_project_stat_done_month, @stats[:done_month], :ok)
            render_stat(:web_project_stat_total,      @stats[:total],      nil)
          end
        end
      end

      STAT_TONES = {
        working: 'var(--work-fg)',
        err: 'var(--err-fg)',
        ok: 'var(--ok-fg)'
      }.freeze
      private_constant :STAT_TONES

      def render_stat(label_key, value, tone)
        color = STAT_TONES[tone] || 'var(--text-strong)'
        div do
          div(class: 'stat-label') { t_web(label_key) }
          div(class: 'stat-value', style: "color: #{color};") { plain value.to_s }
        end
      end

      def render_recent_card # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
        recent = @project_issues.first(5)
        render(Components::Card.new(padding: 0)) do
          div(class: 'card-section-header') do
            h3(class: 'card-section-title') { t_web(:web_project_recent_section) }
            render Components::Button.new(kind: :ghost, size: :sm,
                                          href: "/projects/#{project_slug(@project_path)}?tab=issues",
                                          icon_right: Components::Icon.new(
                                            name: 'chevron-r', size: 13
                                          )) { t_web(:web_project_view_all) }
          end
          if recent.empty?
            div(class: 'empty-state') { p(class: 'muted') { t_web(:web_project_no_recent) } }
          else
            recent.each_with_index { |row, idx| render_recent_row(row, idx == recent.size - 1) }
          end
        end
      end

      def render_recent_row(row, last)
        a(href: "/issues/#{row[:id]}", class: 'recent-row',
          style: "border-bottom: #{last ? 'none' : '1px solid var(--divider)'};") do
          span(class: 'iid-mono') { plain "##{row[:issue_iid]}" }
          div(style: 'min-width: 0;') do
            div(class: 'recent-title') { row[:issue_title] }
            div(class: 'recent-meta') { relative_time(row[:created_at]) }
          end
          render status_pill(row[:status], size: :sm)
        end
      end

      def render_technical_card
        render(Components::Card.new) do
          h3(class: 'sidecard-title') { t_web(:web_project_technical_details) }
          div(class: 'kv-grid') do
            render_kv(t_web(:web_project_branch_label),
                      @project_config['target_branch'] || t_web(:web_project_branch_unset),
                      mono: true)
            render_kv(t_web(:web_project_extra_prompt_label), extra_prompt_summary)
            render_kv(t_web(:web_project_post_completion_label), post_completion_summary)
          end
        end
      end

      def render_kv(label, value, mono: false)
        div(class: 'kv-row') do
          span(class: 'kv-label') { label }
          if mono
            span(class: 'kv-value') { code { plain value.to_s } }
          else
            span(class: 'kv-value') { plain value.to_s }
          end
        end
      end

      def extra_prompt_summary
        prompt = @project_config['extra_prompt']
        return t_web(:web_project_extra_prompt_unset) if prompt.nil? || prompt.empty?

        prompt.length > 60 ? "#{prompt[0, 57]}…" : prompt
      end

      def post_completion_summary
        cmd = @project_config['post_completion']
        return t_web(:web_project_post_completion_unset) if cmd.nil? || (cmd.respond_to?(:empty?) && cmd.empty?)

        cmd.is_a?(Array) ? cmd.join(' ') : cmd.to_s
      end

      def render_team_preview_card
        render(Components::Card.new) do
          h3(class: 'sidecard-title') { t_web(:web_project_team_section) }
          div(class: 'coming-soon', title: t_web(:web_coming_soon_tooltip)) do
            p(class: 'muted', style: 'font-size: 12px; margin: 0;') do
              t_web(:web_project_team_coming_soon)
            end
          end
        end
      end

      # === Issues tab ======================================================

      def render_issues_tab
        return render_empty(:web_project_no_issues) if @project_issues.empty?

        render(Components::Card.new(padding: 0)) do
          @project_issues.each_with_index do |row, idx|
            render_issues_tab_row(row, idx == @project_issues.size - 1)
          end
        end
      end

      def render_issues_tab_row(row, last)
        a(href: "/issues/#{row[:id]}", class: 'project-issue-row',
          style: "border-bottom: #{last ? 'none' : '1px solid var(--divider)'};") do
          span(class: 'iid-mono', style: 'flex: 0 0 auto;') { plain "##{row[:issue_iid]}" }
          div(style: 'flex: 1; min-width: 200px;') do
            div(class: 'recent-title') { row[:issue_title] }
            div(class: 'recent-meta') { relative_time(row[:created_at]) }
          end
          render status_pill(row[:status], size: :sm)
        end
      end

      # === Config tab ======================================================

      def render_config_tab
        div(class: 'project-config-grid') do
          render_yaml_card
          render_toggles_column
        end
      end

      def render_yaml_card # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
        render(Components::Card.new(padding: 0)) do
          div(class: 'yaml-header') do
            div(style: 'display: flex; align-items: center; gap: 8px;') do
              render Components::Icon.new(name: 'settings', size: 14, color: 'var(--text-muted)')
              span(class: 'yaml-filename') { t_web(:web_project_config_yaml_title) }
            end
            span(class: 'coming-soon', title: t_web(:web_coming_soon_tooltip)) do
              render Components::Button.new(size: :sm, href: '#',
                                            icon: Components::Icon.new(name: 'copy', size: 12)) do
                t_web(:web_project_config_copy)
              end
            end
          end
          if @project_config.empty?
            div(class: 'empty-state') { p(class: 'muted') { t_web(:web_project_no_config) } }
          else
            pre(class: 'yaml-pre') { YAML.dump(@project_config) }
          end
        end
      end

      def render_toggles_column # rubocop:disable Metrics/MethodLength
        div(style: 'display: flex; flex-direction: column; gap: 22px;') do
          render(Components::Card.new) do
            h3(class: 'sidecard-title') { t_web(:web_project_behavior_section) }
            div(class: 'coming-soon', title: t_web(:web_coming_soon_tooltip)) do
              p(class: 'muted', style: 'font-size: 12px; margin: 0;') do
                t_web(:web_coming_soon)
              end
            end
          end
          render(Components::Card.new) do
            h3(class: 'sidecard-title') { t_web(:web_project_security_section) }
            div(class: 'coming-soon', title: t_web(:web_coming_soon_tooltip)) do
              p(class: 'muted', style: 'font-size: 12px; margin: 0;') do
                t_web(:web_coming_soon)
              end
            end
          end
        end
      end

      # === Team tab ========================================================

      def render_team_tab
        render(Components::Card.new) do
          div(class: 'coming-soon', title: t_web(:web_coming_soon_tooltip)) do
            p(class: 'muted', style: 'margin: 0;') { t_web(:web_project_team_coming_soon) }
          end
        end
      end

      def render_empty(message_key)
        div(class: 'empty-state') { p(class: 'muted') { t_web(message_key) } }
      end
    end
  end
end
