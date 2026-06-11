# frozen_string_literal: true

module Web
  module Views
    module Admin
      # GET /admin/users — read-only audit of who exists in `users` and
      # what `project_memberships` GitLab has granted them.
      class Users < Base # rubocop:disable Metrics/ClassLength
        def initialize(users:, **)
          super(**)
          @users = users
        end

        def view_template
          with_layout(nav: false, shell: false) do
            div(class: 'app-shell') do
              render_sidebar
              main { render_main }
            end
          end
        end

        private

        def render_main
          render_topbar
          div(class: 'admin-content', style: 'flex: 1; overflow: auto;') do
            @users.empty? ? render_empty : render_table
          end
        end

        def render_sidebar
          render Components::Sidebar.new(
            active: 'admin', locale: web_locale, request_path: @request_path,
            counts: {}, translator: ->(key, **vars) { t_web(key, **vars) }, admin: @current_user_admin
          )
        end

        def render_topbar
          render Components::Topbar.new(
            title: t_web(:web_admin_users_title),
            subtitle: t_web(:web_admin_users_subtitle),
            breadcrumb: t_web(:web_admin_users_breadcrumb)
          )
        end

        def render_empty
          render(Components::Card.new) do
            div(class: 'empty-state') do
              p(class: 'muted') { plain t_web(:web_admin_users_empty) }
            end
          end
        end

        def render_table
          div(style: 'display: flex; flex-direction: column; gap: 12px;') do
            render_summary
            div(class: 'admin-users-table') do
              render_header
              @users.each { |u| render_user_row(u) }
            end
          end
        end

        def render_summary
          count = @users.size
          key = count == 1 ? :web_admin_users_count_one : :web_admin_users_count_many
          span(style: 'font-size: 12px; color: var(--text-muted);') do
            plain t_web(key, count: count)
          end
        end

        def render_header
          div(class: 'admin-users-header') do
            span { t_web(:web_admin_users_col_user) }
            span { t_web(:web_admin_users_col_gitlab) }
            span { t_web(:web_admin_users_col_role) }
            span { t_web(:web_admin_users_col_status) }
            span { t_web(:web_admin_users_col_memberships) }
          end
        end

        def render_user_row(user)
          div(class: 'admin-user-row') do
            render_identity(user)
            render_gitlab(user)
            render_role(user)
            render_status(user)
            render_memberships(user)
          end
        end

        def render_identity(user)
          div(class: 'admin-user-identity') do
            div(class: 'admin-user-avatar') { plain initial_for(user) }
            div(class: 'admin-user-info') do
              div(class: 'admin-user-name') { plain display_name(user) }
              div(class: 'admin-user-email') { plain user.email }
            end
          end
        end

        def initial_for(user)
          source = user.name.presence || user.email.to_s
          source.strip[0]&.upcase || '?'
        end

        def display_name(user)
          user.name.presence || user.email.to_s.split('@').first.to_s
        end

        def render_gitlab(user)
          handle = user.gitlab_username.to_s
          if handle.empty?
            span(class: 'admin-user-gitlab muted') { plain t_web(:web_admin_users_no_gitlab) }
          else
            span(class: 'admin-user-gitlab') { plain "@#{handle}" }
          end
        end

        PILL_BASE_STYLE = 'display: inline-flex; align-items: center; gap: 5px; ' \
                          'padding: 2px 8px; font-size: 11px; font-weight: 500; ' \
                          'line-height: 1.4; white-space: nowrap; border-radius: var(--r-pill);'
        DOT_STYLE = 'width: 5px; height: 5px; border-radius: 50%; flex: 0 0 auto;'
        private_constant :PILL_BASE_STYLE, :DOT_STYLE

        def render_role(user)
          if user.admin?
            span(style: "#{PILL_BASE_STYLE} background: var(--accent-bg); color: var(--accent-fg);") do
              plain t_web(:web_admin_users_role_admin)
            end
          else
            span(style: 'font-size: 12px; color: var(--text-muted);') do
              plain t_web(:web_admin_users_role_member)
            end
          end
        end

        def render_status(user)
          user.disabled_at.present? ? render_status_disabled(user) : render_status_active
        end

        def render_status_active
          span(style: "#{PILL_BASE_STYLE} background: var(--ok-bg); color: var(--ok-fg);") do
            span(style: "#{DOT_STYLE} background: var(--ok-500);")
            plain t_web(:web_admin_users_status_active)
          end
        end

        def render_status_disabled(user)
          span(style: "#{PILL_BASE_STYLE} background: var(--err-bg); color: var(--err-fg);") do
            span(style: "#{DOT_STYLE} background: var(--err-500);")
            plain t_web(:web_admin_users_status_disabled, date: user.disabled_at.to_date)
          end
        end

        def render_memberships(user)
          memberships = user.project_memberships.includes(:project).order('projects.gitlab_path')
          if memberships.empty?
            span(style: 'font-size: 12px; color: var(--text-subtle);') do
              plain t_web(:web_admin_users_memberships_none)
            end
          else
            div(class: 'admin-memberships') { memberships.each { |pm| render_membership(pm) } }
          end
        end

        def render_membership(membership)
          role = membership.role.to_s
          div(class: 'admin-membership', title: "#{membership.project.gitlab_path} (#{role})") do
            span(class: 'admin-membership-path') { plain membership.project.gitlab_path }
            span(class: role_chip_class(role)) { plain role }
          end
        end

        def role_chip_class(role)
          role == ProjectMembership::ROLE_OWNER ? 'admin-membership-role owner' : 'admin-membership-role'
        end
      end
    end
  end
end
