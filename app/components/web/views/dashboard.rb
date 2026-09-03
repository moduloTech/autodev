# frozen_string_literal: true

module Web
  module Views
    # GET / — sidebar + topbar + KPI grid + active list + sparkline + projects + error banner.
    # Mirrors design/screen-dashboard.jsx.
    class Dashboard < Base # rubocop:disable Metrics/ClassLength
      # rubocop:disable Metrics/ParameterLists
      def initialize(active:, errored:, kpis:, weekly_activity:, by_project:,
                     anthropic_configured: true, drafts_awaiting_my_vote: [],
                     usage_state: { available: true, checked_at: nil }, **)
        super(**)
        @active = active
        @errored = errored
        @kpis = kpis
        @weekly_activity = weekly_activity
        @by_project = by_project
        @anthropic_configured = anthropic_configured
        @drafts_awaiting_my_vote = drafts_awaiting_my_vote
        @usage_state = usage_state
      end
      # rubocop:enable Metrics/ParameterLists

      def view_template # rubocop:disable Metrics/MethodLength
        with_layout(nav: false, shell: false) do
          div(class: 'app-shell') do
            render_sidebar
            main do
              render_topbar
              div(style: 'flex: 1; overflow: auto; padding: 32px;') do
                render_usage_paused_banner if usage_paused?
                render_anthropic_missing_banner if show_anthropic_banner?
                render_kpis
                render_drafts_awaiting_my_vote if @drafts_awaiting_my_vote.any?
                render_split
                render_error_banner if @errored.any?
              end
            end
          end
        end
      end

      private

      def render_sidebar
        render Components::Sidebar.new(
          active: 'dashboard', locale: web_locale, request_path: @request_path,
          counts: sidebar_counts,
          translator: ->(key, **vars) { t_web(key, **vars) }, admin: @current_user_admin,
          current_user_email: @current_user_email, csrf_token: @csrf_token
        )
      end

      def render_topbar # rubocop:disable Metrics/MethodLength
        render(Components::Topbar.new(
                 title: t_web(:web_dashboard_greeting),
                 subtitle: t_web(:web_dashboard_subtitle)
               )) do
          render Components::Button.new(kind: :secondary, size: :md,
                                        icon: Components::Icon.new(name: 'refresh', size: 14),
                                        href: '/') { t_web(:web_dashboard_refresh) }
          render Components::Button.new(kind: :primary, size: :md,
                                        icon: Components::Icon.new(name: 'plus', size: 14),
                                        href: '/autospec_drafts/new') do
            t_web(:web_dashboard_new_request)
          end
        end
      end

      KPI_DEFS = [
        { metric: :active,         tone: :working, icon: 'play', href: '/issues?tab=active',
          label_key: :web_kpi_in_progress,         hint_key: :web_kpi_in_progress_hint },
        { metric: :pending,        tone: :working, icon: 'clock', href: '/issues?tab=pending',
          label_key: :web_kpi_pending,             hint_key: :web_kpi_pending_hint },
        { metric: :errors,         tone: :err,     icon: 'alert-tri', href: '/issues?tab=errors',
          label_key: :web_kpi_errors,              hint_key: :web_kpi_errors_hint },
        { metric: :awaiting,       tone: :warn,    icon: 'messages', href: '/issues?tab=waiting',
          label_key: :web_kpi_awaiting_response,   hint_key: :web_kpi_awaiting_response_hint },
        { metric: :delivered_review, tone: :warn,  icon: 'alert-tri', href: '/issues?tab=delivered_review',
          label_key: :web_kpi_delivered_review,    hint_key: :web_kpi_delivered_review_hint },
        { metric: :delivered_week, tone: :ok,      icon: 'check', href: '/issues?tab=done',
          label_key: :web_kpi_delivered_this_week, hint_key: :web_kpi_delivered_this_week_hint }
      ].freeze
      private_constant :KPI_DEFS

      def render_kpis # rubocop:disable Metrics/MethodLength
        div(class: 'kpi-grid') do
          KPI_DEFS.each do |kpi|
            render Components::Kpi.new(
              label: t_web(kpi[:label_key]),
              value: @kpis[kpi[:metric]] || 0,
              tone: kpi[:tone],
              icon_name: kpi[:icon],
              hint: t_web(kpi[:hint_key]),
              href: kpi[:href]
            )
          end
        end
      end

      def render_split
        div(class: 'split-grid') do
          render_active_card
          div(style: 'display: flex; flex-direction: column; gap: 20px;') do
            render_activity_card
            render_projects_card
          end
        end
      end

      def render_active_card # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
        render(Components::Card.new(padding: 0)) do
          div(style: card_header_style) do
            div(style: 'display: flex; align-items: center; gap: 10px;') do
              h3(style: card_title_style) { t_web(:web_dashboard_active_section) }
              span(style: 'font-size: 12px; color: var(--text-muted);') do
                t_web(:web_dashboard_active_count, count: @active.size)
              end
            end
            render Components::Button.new(kind: :ghost, size: :sm, href: '/issues',
                                          icon_right: Components::Icon.new(
                                            name: 'chevron-r', size: 13
                                          )) { t_web(:web_dashboard_view_all) }
          end
          div do
            @active.first(5).each_with_index do |row, idx|
              render_active_row(row, idx == [@active.size, 5].min - 1)
            end
          end
        end
      end

      def card_header_style
        'display: flex; align-items: center; justify-content: space-between; ' \
          'padding: 16px 20px; border-bottom: 1px solid var(--border);'
      end

      def card_title_style
        'margin: 0; font-size: 14px; font-weight: 600; color: var(--text-strong);'
      end

      def render_active_row(row, last) # rubocop:disable Metrics/AbcSize
        a(href: "/issues/#{row[:id]}", style: active_row_style(last)) do
          div(style: iid_chip_style) { plain "##{row[:issue_iid]}" }
          div(style: 'min-width: 0;') do
            div(style: row_title_style) { row[:issue_title] }
            div(style: row_meta_style) do
              plain row[:project_path]
            end
          end
          render status_pill(issue_status(row), size: :sm)
        end
      end

      def active_row_style(last)
        border = last ? 'none' : '1px solid var(--divider)'
        'display: grid; grid-template-columns: auto 1fr auto; align-items: center; gap: 14px; ' \
          "padding: 12px 20px; border-bottom: #{border}; text-decoration: none; color: inherit;"
      end

      def iid_chip_style
        'width: 32px; height: 32px; border-radius: 8px; background: var(--paper-2); ' \
          'display: inline-flex; align-items: center; justify-content: center; ' \
          'font-size: 10px; font-weight: 600; color: var(--text-muted); ' \
          'font-family: var(--font-mono);'
      end

      def row_title_style
        'font-size: 13px; font-weight: 500; color: var(--text-strong); ' \
          'white-space: nowrap; text-overflow: ellipsis; overflow: hidden;'
      end

      def row_meta_style
        'font-size: 11px; color: var(--text-muted); margin-top: 2px; ' \
          'white-space: nowrap; text-overflow: ellipsis; overflow: hidden;'
      end

      DAY_KEYS = %i[web_day_mon web_day_tue web_day_wed web_day_thu web_day_fri web_day_sat web_day_sun].freeze
      private_constant :DAY_KEYS

      def render_activity_card
        render(Components::Card.new) do
          h3(style: 'margin: 0 0 14px; font-size: 14px; font-weight: 600; color: var(--text-strong);') do
            t_web(:web_dashboard_weekly_activity)
          end
          render Components::Sparkline.new(values: rotated_weekly_activity)
          div(style: 'display: flex; justify-content: space-between; margin-top: 12px; ' \
                     'font-size: 11px; color: var(--text-muted);') do
            DAY_KEYS.rotate(Date.today.cwday - 7).each { |key| span { t_web(key) } }
          end
        end
      end

      # The sparkline data starts 6 days ago and ends today (left-to-right).
      # The day labels need to match that sliding window — rotate so today's
      # day-of-week ends up rightmost.
      def rotated_weekly_activity
        @weekly_activity
      end

      def render_projects_card
        render(Components::Card.new(padding: 0)) do
          div(style: 'padding: 14px 18px 10px; border-bottom: 1px solid var(--border);') do
            h3(style: card_title_style) { t_web(:web_dashboard_your_projects) }
          end
          div { @by_project.each_with_index { |stats, idx| render_project_row(stats, idx == @by_project.size - 1) } }
        end
      end

      def render_project_row(stats, last) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        a(href: "/projects/#{project_slug(stats[:path])}", style: project_row_style(last)) do
          span(style: 'width: 8px; height: 8px; border-radius: 2px; ' \
                      "background: #{project_dot_color(stats[:path])}; flex: 0 0 auto;")
          div(style: 'flex: 1; min-width: 0;') do
            div(style: 'font-size: 13px; font-weight: 500; color: var(--text);') { stats[:path] }
            div(style: 'font-size: 11px; color: var(--text-muted);') do
              t_web(:web_project_total_requests, count: stats[:total])
            end
          end
          div(style: 'display: flex; align-items: center; gap: 8px;') do
            render_project_error_badge(stats[:error]) if stats[:error].positive?
            span(style: 'font-size: 11px; font-weight: 600; color: var(--text);') do
              t_web(:web_project_active_count, count: stats[:active])
            end
          end
        end
      end

      def project_row_style(last)
        border = last ? 'none' : '1px solid var(--divider)'
        'display: flex; align-items: center; gap: 12px; padding: 11px 18px; ' \
          "border-bottom: #{border}; text-decoration: none; color: inherit;"
      end

      def render_project_error_badge(count)
        span(style: 'font-size: 11px; color: var(--err-fg); background: var(--err-bg); ' \
                    'padding: 2px 7px; border-radius: var(--r-pill);') do
          t_web(:web_project_error_badge, count: count)
        end
      end

      def render_error_banner # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
        banner_style = 'border-color: var(--err-200); ' \
                       'background: linear-gradient(180deg, var(--err-bg), var(--paper) 60%);'
        div(style: 'margin-top: 20px;') do
          render(Components::Card.new(padding: 0, extra_style: banner_style)) do
            div(style: 'display: flex; align-items: center; gap: 14px; padding: 16px 20px;') do
              div(style: 'display: flex; align-items: center; gap: 14px; flex: 1;') do
                span(style: error_icon_box_style) { render Components::Icon.new(name: 'alert-tri', size: 18) }
                div do
                  div(style: 'font-size: 14px; font-weight: 600; color: var(--text-strong);') do
                    plain error_banner_text
                  end
                  div(style: 'font-size: 12px; color: var(--text-muted); margin-top: 2px;') do
                    t_web(:web_dashboard_error_banner_hint)
                  end
                end
              end
              render Components::Button.new(kind: :danger, size: :md, href: '/issues?tab=errors') do
                t_web(:web_dashboard_view_failures)
              end
            end
          end
        end
      end

      # AutoSpec drafts awaiting the current user's vote (step 11c).
      # Hidden when empty — only owners of at least one project + a
      # pending draft + no vote yet at current_iteration land here.
      def render_drafts_awaiting_my_vote # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
        div(style: 'margin: 20px 0;') do
          render(Components::Card.new(padding: 0)) do
            div(style: card_header_style) do
              h3(style: card_title_style) { t_web(:web_dashboard_drafts_to_vote) }
              span(style: 'font-size: 12px; color: var(--text-muted);') do
                plain @drafts_awaiting_my_vote.size.to_s
              end
            end
            div do
              @drafts_awaiting_my_vote.each_with_index do |d, idx|
                render_draft_to_vote_row(d, idx == @drafts_awaiting_my_vote.size - 1)
              end
            end
          end
        end
      end

      def render_draft_to_vote_row(draft, last) # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
        a(href: "/autospec_drafts/#{draft.id}", style: active_row_style(last)) do
          div(style: iid_chip_style) { plain "##{draft.current_iteration}" }
          div(style: 'min-width: 0;') do
            div(style: row_title_style) { plain(draft.title.presence || t_web(:web_autospec_untitled)) }
            div(style: row_meta_style) do
              plain "#{draft.project.gitlab_path} · #{t_web(:web_dashboard_drafts_to_vote_author,
                                                            email: draft.user.email)}"
            end
          end
          span(style: 'font-size: 11px; color: var(--warn-fg); background: var(--warn-bg); ' \
                      'padding: 2px 7px; border-radius: var(--r-pill);') do
            t_web(:web_dashboard_drafts_to_vote_cta)
          end
        end
      end

      # Surface a setup warning to admins when the AutoSpec chat cannot
      # run. Hidden from non-admin users — they can't fix it, so the
      # banner would just be noise. Mirrors the `render_error_banner`
      # treatment but in the warn palette.
      def show_anthropic_banner?
        @current_user_admin && !@anthropic_configured
      end

      def render_anthropic_missing_banner
        render_warn_banner(t_web(:web_dashboard_anthropic_missing_title),
                           t_web(:web_dashboard_anthropic_missing_hint))
      end

      # Claude quota outage (Autodev #46). Shown to every signed-in user, not
      # just admins: the pause holds up everyone's tickets, and the copy has to
      # say what still runs or the banner reads as "autodev is down".
      def usage_paused? = @usage_state[:available] == false

      # The three fault causes Autodev #108 added to the recorded verdict — a
      # dead credential, an absent binary, or an unrecognised failure — are not
      # the quota, and reusing "Quota Claude épuisé" for a broken Docker engine
      # is the exact defect this ticket exists to end: autodev asserting
      # something its own state contradicts. `quota_exhausted`, and a
      # pre-upgrade row carrying no `status` at all, keep the verbatim wording.
      # Deliberately NOT debounced, unlike `/healthz`'s `danger_claude` card,
      # which warns on a first `broken` and only pages on the second (second
      # neutral review, N12). A banner wakes nobody, and telling the operator
      # looking at the dashboard right now is the point; the debounce exists for
      # the external pager. The two surfaces therefore disagree for one cycle on
      # an isolated fault, and that is the intended reading of each.
      DANGER_CLAUDE_FAULT_STATUSES = %i[auth_refused binary_missing broken].freeze
      private_constant :DANGER_CLAUDE_FAULT_STATUSES

      def render_usage_paused_banner
        title, hint = usage_paused_copy
        render_warn_banner(title, hint)
      end

      def usage_paused_copy
        checked_at = relative_time(@usage_state[:checked_at])
        if danger_claude_fault?
          return [t_web(:web_dashboard_danger_claude_broken_title),
                  t_web(:web_dashboard_danger_claude_broken_hint, checked_at: checked_at)]
        end

        [t_web(:web_dashboard_usage_paused_title), t_web(:web_dashboard_usage_paused_hint, checked_at: checked_at)]
      end

      def danger_claude_fault?
        DANGER_CLAUDE_FAULT_STATUSES.include?(@usage_state[:status])
      end

      def render_warn_banner(title, hint) # rubocop:disable Metrics/MethodLength
        banner_style = 'border-color: var(--warn-200); ' \
                       'background: linear-gradient(180deg, var(--warn-bg), var(--paper) 60%);'
        div(style: 'margin-bottom: 20px;') do
          render(Components::Card.new(padding: 0, extra_style: banner_style)) do
            div(style: 'display: flex; align-items: center; gap: 14px; padding: 16px 20px;') do
              span(style: warn_icon_box_style) do
                render Components::Icon.new(name: 'alert-tri', size: 18)
              end
              div(style: 'flex: 1;') do
                div(style: 'font-size: 14px; font-weight: 600; color: var(--text-strong);') { title }
                div(style: 'font-size: 12px; color: var(--text-muted); margin-top: 2px;') { hint }
              end
            end
          end
        end
      end

      def warn_icon_box_style
        'width: 36px; height: 36px; border-radius: 10px; background: var(--warn-bg); ' \
          'color: var(--warn-fg); display: inline-flex; align-items: center; justify-content: center; ' \
          'flex: 0 0 auto;'
      end

      def error_icon_box_style
        'width: 36px; height: 36px; border-radius: 10px; background: var(--err-bg); ' \
          'color: var(--err-fg); display: inline-flex; align-items: center; justify-content: center; ' \
          'flex: 0 0 auto;'
      end

      def error_banner_text
        if @errored.size == 1
          t_web(:web_dashboard_error_banner_one)
        else
          t_web(:web_dashboard_error_banner_many, count: @errored.size)
        end
      end
    end
  end
end
