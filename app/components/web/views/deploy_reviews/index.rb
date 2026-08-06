# frozen_string_literal: true

module Web
  module Views
    module DeployReviews
      # GET /deploy_review — sidebar + topbar + project selector + (when a
      # visible project is selected) the list of its open MRs, each with a
      # lazy deploy/redeploy `DeployReviewFrame` and, when a matching Issue
      # row exists, a "tracked by autodev" badge linking to the ticket
      # (task #43). Every open MR is listed — tracked ones are annotated,
      # not hidden, since (re)deploying is idempotent either way.
      class Index < Base # rubocop:disable Metrics/ClassLength
        # rubocop:disable Metrics/ParameterLists
        def initialize(projects:, selected_project:, merge_requests:, tracked_issue_ids:, error:, kpis:,
                       query: nil, untracked_only: false, **)
          @projects = projects
          @selected_project = selected_project
          @merge_requests = merge_requests
          @tracked_issue_ids = tracked_issue_ids
          @query = query
          @untracked_only = untracked_only
          @error = error
          @kpis = kpis
          super(**)
        end
        # rubocop:enable Metrics/ParameterLists

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
          div(class: 'deploy-review-content', style: 'flex: 1; overflow: auto; padding: 28px;') do
            render_selector
            render_body
          end
        end

        def render_sidebar
          render Components::Sidebar.new(
            active: 'deploy_review', locale: web_locale, request_path: @request_path,
            counts: sidebar_counts, translator: ->(key, **vars) { t_web(key, **vars) },
            admin: @current_user_admin, current_user_email: @current_user_email, csrf_token: @csrf_token
          )
        end

        def render_topbar
          render Components::Topbar.new(
            title: t_web(:web_deploy_review_title), subtitle: t_web(:web_deploy_review_subtitle)
          )
        end

        # One form carries project + search + filter, so a submit never drops
        # part of the state (Autodev #45).
        def render_selector
          form(method: 'get', action: '/deploy_review', style: 'display: flex; align-items: center; ' \
                                                               'gap: 8px; margin-bottom: 8px; flex-wrap: wrap;') do
            label { t_web(:web_deploy_review_project_label) }
            select(name: 'project') { @projects.each { |p| render_project_option(p) } }
            render_search_input
            render_untracked_checkbox
            button(type: 'submit', class: 'btn btn-primary-sm') { t_web(:web_deploy_review_apply) }
          end
          render_search_hint
        end

        def render_search_input
          input(type: 'search', name: 'q', value: @query, style: 'min-width: 260px;',
                placeholder: t_web(:web_deploy_review_search_placeholder),
                'aria-label' => t_web(:web_deploy_review_search_placeholder))
        end

        def render_untracked_checkbox
          label(style: 'display: inline-flex; align-items: center; gap: 6px; font-weight: 400;') do
            attrs = { type: 'checkbox', name: 'untracked', value: '1' }
            attrs[:checked] = true if @untracked_only
            input(**attrs)
            plain t_web(:web_deploy_review_untracked_label)
          end
        end

        # Says out loud that a ticket number works — the whole point of the
        # search is that the person arrives with one and nothing told them so.
        def render_search_hint
          p(class: 'muted', style: 'font-size: 12px; margin: 0 0 20px;') do
            t_web(:web_deploy_review_search_hint)
          end
        end

        def render_project_option(project)
          attrs = { value: project.gitlab_path }
          attrs[:selected] = true if project.gitlab_path == @selected_project
          option(**attrs) { project.gitlab_path }
        end

        def render_body
          return render_empty(:web_deploy_review_no_projects) if @projects.empty?
          return unless @selected_project

          return render_empty(:web_deploy_review_api_error) if @error
          return render_empty(empty_key) if @merge_requests.blank?

          render_count
          render_mr_list
        end

        # An empty result under a search means "no match", not "nothing to
        # deploy" — collapsing the two is how a working feature reads as broken.
        def empty_key
          return :web_deploy_review_no_matches if @query.present?
          return :web_deploy_review_no_untracked_mrs if @untracked_only

          :web_deploy_review_no_mrs
        end

        def render_count
          p(class: 'muted', style: 'font-size: 12px; margin: 0 0 12px;') do
            t_web(:web_deploy_review_count, count: @merge_requests.size)
          end
        end

        def render_empty(key)
          p(class: 'muted') { t_web(key) }
        end

        def render_mr_list
          div(style: 'display: flex; flex-direction: column; gap: 12px;') do
            @merge_requests.each { |merge_request| render_mr_card(merge_request) }
          end
        end

        def render_mr_card(merge_request)
          iid = mr_field(merge_request, :iid)
          render(Components::Card.new) do
            div(style: 'display: flex; justify-content: space-between; gap: 16px; align-items: flex-start;') do
              render_mr_details(merge_request, iid)
              div(style: 'width: 180px; flex: 0 0 auto;') { render_deploy_frame(iid) }
            end
          end
        end

        def render_mr_details(merge_request, iid)
          div(style: 'min-width: 0; flex: 1;') do
            div(style: 'font-weight: 600;') { mr_field(merge_request, :title) }
            div(class: 'muted', style: 'font-size: 12px; margin-top: 2px;') do
              plain "!#{iid} · #{mr_field(merge_request, :source_branch)} · #{mr_author_name(merge_request)}"
            end
            render_tracked_badge(iid) if @tracked_issue_ids.key?(iid)
          end
        end

        def mr_author_name(merge_request)
          author = mr_field(merge_request, :author)
          return nil unless author

          GitlabHelpers.field(author, :name) || GitlabHelpers.field(author, :username)
        end

        def render_tracked_badge(iid)
          a(href: "/issues/#{@tracked_issue_ids[iid]}", style: tracked_badge_style) do
            plain t_web(:web_deploy_review_tracked_badge)
          end
        end

        def tracked_badge_style
          'display: inline-flex; align-items: center; gap: 4px; margin-top: 6px; ' \
            'font-size: 11px; font-weight: 600; padding: 1px 7px; border-radius: var(--r-pill); ' \
            'background: var(--accent-bg); color: var(--accent-fg); text-decoration: none;'
        end

        def render_deploy_frame(iid)
          render Web::Views::DeployReviewFrame.new(
            state: :loading,
            frame_id: Web::Views::DeployReviewFrame.mr_frame_id(@selected_project, iid),
            src: "/deploy_review/mr?project=#{CGI.escape(@selected_project)}&mr_iid=#{iid}",
            submit_action: '/deploy_review/mr',
            hidden_fields: { project: @selected_project, mr_iid: iid },
            locale: web_locale, csrf_token: @csrf_token
          )
        end

        def mr_field(merge_request, name)
          GitlabHelpers.field(merge_request, name)
        end
      end
    end
  end
end
