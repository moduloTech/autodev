# frozen_string_literal: true

module Web
  module Views
    module Admin
      # GET /admin/users — read-only audit of who exists in `users` and
      # what `project_memberships` GitLab has granted them. Stripped chrome
      # (no sidebar): the page is admin-only and benefits from horizontal
      # real estate for the project × user matrix.
      class Users < Base
        def initialize(users:, **)
          super(**)
          @users = users
        end

        def view_template
          with_layout(nav: true, shell: true) do
            div(style: 'padding: 24px;') do
              h1(style: 'margin: 0 0 8px 0;') { plain 'Admin — Users' }
              p(class: 'muted', style: 'margin: 0 0 24px 0;') do
                plain "#{@users.size} user(s). Memberships are synced from GitLab — edit there, not here."
              end
              @users.empty? ? render_empty : render_table
            end
          end
        end

        private

        def render_empty
          div(class: 'empty-state') do
            p(class: 'muted') { plain 'No users yet. Seed one via `bin/rails autodev:seed_admin EMAIL=…`.' }
          end
        end

        TABLE_STYLE = 'width: 100%; border-collapse: collapse;'
        TH_STYLE = 'text-align: left; padding: 8px 12px; border-bottom: 1px solid var(--border); ' \
                   'font-size: 12px; text-transform: uppercase; color: var(--text-muted);'
        TD_STYLE = 'padding: 12px; border-bottom: 1px solid var(--border); vertical-align: top;'
        private_constant :TABLE_STYLE, :TH_STYLE, :TD_STYLE

        def render_table
          table(style: TABLE_STYLE) do
            thead { render_header_row }
            tbody { @users.each { |u| render_user_row(u) } }
          end
        end

        def render_header_row
          tr do
            %w[Email Name Admin GitLab Status Memberships].each do |label|
              th(style: TH_STYLE) { plain label }
            end
          end
        end

        def render_user_row(user) # rubocop:disable Metrics/AbcSize
          tr do
            td(style: TD_STYLE) { plain user.email }
            td(style: TD_STYLE) { plain user.name.to_s }
            td(style: TD_STYLE) { plain(user.admin? ? '✓' : '') }
            td(style: TD_STYLE) { plain user.gitlab_username.to_s }
            td(style: TD_STYLE) { render_status(user) }
            td(style: TD_STYLE) { render_memberships(user) }
          end
        end

        def render_status(user)
          if user.disabled_at.present?
            span(style: 'color: var(--err-fg);') { plain "disabled #{user.disabled_at.to_date}" }
          else
            span(style: 'color: var(--ok-fg);') { plain 'active' }
          end
        end

        def render_memberships(user)
          memberships = user.project_memberships.includes(:project).order('projects.gitlab_path')
          if memberships.empty?
            span(class: 'muted') { plain '(none)' }
          else
            ul(style: 'margin: 0; padding-left: 18px;') do
              memberships.each { |pm| li { plain "#{pm.project.gitlab_path} (#{pm.role})" } }
            end
          end
        end
      end
    end
  end
end
