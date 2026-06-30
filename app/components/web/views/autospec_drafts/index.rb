# frozen_string_literal: true

module Web
  module Views
    module AutospecDrafts
      # GET /autospec_drafts — the signed-in user's drafts, filtered by a tab
      # bar modelled on the /issues view. The status tabs (Toutes / En rédaction
      # / En attente de validation / Rejetés / Approuvés) list the user's own
      # drafts; "À valider" is the owner-vote set (drafts on projects they own
      # that await their vote). Row rendering is unchanged from the 10a slice.
      class Index < Web::Views::Base # rubocop:disable Metrics/ClassLength
        include Concerns::FilterTabs

        TABS = [
          { id: 'all',          label_key: :web_autospec_tab_all,          count_key: :all },
          { id: 'drafting',     label_key: :web_autospec_tab_drafting,     count_key: :drafting },
          { id: 'pending',      label_key: :web_autospec_tab_pending,      count_key: :pending },
          { id: 'to_validate',  label_key: :web_autospec_tab_to_validate,  count_key: :to_validate,
            tone: :warn },
          { id: 'rejected',     label_key: :web_autospec_tab_rejected,     count_key: :rejected },
          { id: 'approved',     label_key: :web_autospec_tab_approved,     count_key: :approved }
        ].freeze
        private_constant :TABS

        # Maps the active tab to the matching sidebar nav id so its entry
        # highlights (only drafting / pending / to_validate have sidebar links).
        SIDEBAR_ACTIVE = { 'drafting' => 'autospec_drafting', 'pending' => 'autospec_pending',
                           'to_validate' => 'autospec_to_validate' }.freeze
        private_constant :SIDEBAR_ACTIVE

        def initialize(drafts:, tab: 'all', tab_counts: {}, kpis: {}, **)
          super(**)
          @drafts = drafts
          @tab = tab
          @tab_counts = tab_counts
          @kpis = kpis
        end

        def view_template # rubocop:disable Metrics/MethodLength
          with_layout(nav: false, shell: false) do
            div(class: 'app-shell') do
              render_sidebar
              main do
                render_topbar
                render_filter_bar
                div(style: 'flex: 1; overflow: auto; padding: 28px;') do
                  @drafts.any? ? render_list : render_empty
                end
              end
            end
          end
        end

        private

        def render_sidebar
          render Components::Sidebar.new(
            active: SIDEBAR_ACTIVE.fetch(@tab, 'autospec'), locale: web_locale,
            request_path: @request_path, counts: sidebar_counts, admin: @current_user_admin,
            translator: ->(key, **vars) { t_web(key, **vars) },
            current_user_email: @current_user_email, csrf_token: @csrf_token
          )
        end

        def render_topbar # rubocop:disable Metrics/MethodLength
          render Components::Topbar.new(
            title: t_web(:web_autospec_index_title),
            subtitle: t_web(:web_autospec_index_subtitle)
          ) do
            a(href: '/autospec_drafts/import', class: 'button',
              style: 'padding: 8px 14px; font-size: 13px;') do
              t_web(:web_autospec_import_cta)
            end
            a(href: '/autospec_drafts/new', class: 'button button-primary',
              style: 'padding: 8px 14px; font-size: 13px;') do
              t_web(:web_autospec_new_cta)
            end
          end
        end

        def render_filter_bar
          div(class: 'filter-bar') do
            div(class: 'filter-tabs') { TABS.each { |tab| render_tab(tab) } }
          end
        end

        def render_tab(tab)
          render_filter_tab(label: t_web(tab[:label_key]), count: @tab_counts[tab[:count_key]] || 0,
                            active: @tab == tab[:id], href: "/autospec_drafts?tab=#{tab[:id]}",
                            tone: tab[:tone])
        end

        def render_empty # rubocop:disable Metrics/MethodLength
          render Components::Card.new(padding: 32) do
            if @tab == 'all'
              p(class: 'muted', style: 'margin: 0 0 12px;') { t_web(:web_autospec_index_empty) }
              a(href: '/autospec_drafts/new', class: 'button button-primary',
                style: 'padding: 8px 14px; font-size: 13px;') do
                t_web(:web_autospec_new_cta)
              end
            else
              p(class: 'muted', style: 'margin: 0;') { t_web(:web_autospec_tab_empty) }
            end
          end
        end

        def render_list
          div(style: 'display: grid; gap: 12px;') do
            @drafts.each { |d| render_row(d) }
          end
        end

        def render_row(draft)
          a(href: "/autospec_drafts/#{draft.id}",
            style: 'text-decoration: none; color: inherit; display: block;') do
            render Components::Card.new(padding: 16) do
              render_row_body(draft)
            end
          end
        end

        def render_row_body(draft) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
          div(style: 'display: flex; justify-content: space-between; align-items: center; gap: 16px;') do
            div(style: 'min-width: 0; flex: 1;') do
              div(style: 'font-weight: 600; font-size: 14px;') do
                plain(draft.title.presence || t_web(:web_autospec_untitled))
              end
              div(class: 'muted', style: 'font-size: 12px; margin-top: 2px;') do
                plain "#{draft.project.gitlab_path} · #{t_web(status_label_key(draft.status))}"
              end
            end
            div(class: 'muted', style: 'font-size: 11px;') do
              plain I18n.l(draft.updated_at, format: :short)
            rescue StandardError
              plain draft.updated_at.to_s
            end
          end
        end

        def status_label_key(status)
          {
            'drafting' => :web_autospec_status_drafting,
            'pending_approval' => :web_autospec_status_pending_approval,
            'rejected' => :web_autospec_status_rejected,
            'submitted' => :web_autospec_status_submitted
          }.fetch(status.to_s, :web_autospec_status_drafting)
        end
      end
    end
  end
end
