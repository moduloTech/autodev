# frozen_string_literal: true

module Web
  module Views
    # GET /projects — sidebar + topbar + grid of project cards.
    # Each card links to /projects/:slug.
    class ProjectsIndex < Base
      def initialize(projects:, kpis:, **)
        super(**)
        @projects = projects
        @kpis = kpis
      end

      def view_template # rubocop:disable Metrics/MethodLength
        with_layout(nav: false, shell: false) do
          div(class: 'app-shell') do
            render_sidebar
            main do
              render_topbar
              div(class: 'projects-index-content', style: 'flex: 1; overflow: auto; padding: 28px;') do
                if @projects.empty?
                  render_empty
                else
                  render_grid
                end
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
          translator: ->(key, **vars) { t_web(key, **vars) }, admin: @current_user_admin
        )
      end

      def render_topbar
        render Components::Topbar.new(
          title: t_web(:web_projects_index_title),
          subtitle: t_web(:web_projects_index_subtitle)
        )
      end

      def render_empty
        div(class: 'empty-state') { p(class: 'muted') { t_web(:web_projects_index_empty) } }
      end

      def render_grid
        div(class: 'projects-grid') do
          @projects.each { |project| render_project_card(project) }
        end
      end

      def render_project_card(project) # rubocop:disable Metrics/MethodLength
        path = project[:path]
        a(href: "/projects/#{project_slug(path)}", class: 'project-index-card') do
          div(class: 'project-card-header') do
            span(class: 'hero-mark', style: "background: #{project_dot_color(path)}; width: 32px; height: 32px; " \
                                            'border-radius: 8px; font-size: 14px;') do
              plain path[0].upcase
            end
            div(style: 'min-width: 0;') do
              div(class: 'project-card-name') { path }
              if (url = gitlab_project_url(path))
                div(class: 'project-card-repo') { url.sub(%r{^https?://}, '') }
              end
            end
          end
          render_project_card_stats(project)
        end
      end

      STAT_DEFS = [
        { key: :active, label: :web_project_stat_active, color: 'var(--work-fg)' },
        { key: :error,  label: :web_project_stat_errors, color: 'var(--err-fg)' },
        { key: :done,   label: :web_project_stat_done_month, color: 'var(--ok-fg)' },
        { key: :total,  label: :web_project_stat_total, color: 'var(--text-strong)' }
      ].freeze
      private_constant :STAT_DEFS

      def render_project_card_stats(project)
        div(class: 'project-card-stats') do
          STAT_DEFS.each do |stat|
            div do
              div(class: 'stat-label') { t_web(stat[:label]) }
              div(class: 'stat-value', style: "color: #{stat[:color]}; font-size: 18px;") do
                plain (project[stat[:key]] || 0).to_s
              end
            end
          end
        end
      end
    end
  end
end
