# frozen_string_literal: true

require 'cgi'

require_relative 'turbo_stream_helpers'
require_relative 'issues_filter'
require_relative 'i18n_helpers'

module Web
  # View helpers exposed to ERB templates and route blocks.
  module Helpers # rubocop:disable Metrics/ModuleLength
    include TurboStreamHelpers
    include IssuesFilter
    include I18nHelpers

    def app_config
      ::Web.config || {}
    end

    # Common kwargs every Phlex view consumes via `Web::Views::Base`. Pulled
    # into a helper so the ~10 controllers that hand-roll `.new(...)` calls
    # share a single source of truth (PR3 of the users-rollout chantier).
    # Controllers spread `**view_kwargs` into their view instantiations.
    def view_kwargs
      user = respond_to?(:current_user) ? current_user : nil
      {
        locale: web_locale,
        request_path: request.fullpath,
        current_user_email: user&.email,
        current_user_admin: user&.admin? || false,
        # `form_authenticity_token` is PRIVATE on ActionController::Base, so
        # `respond_to?(:form_authenticity_token)` (default) returns false —
        # which silently dropped the CSRF token from every Phlex form since
        # the users-rollout PR3. Pass `true` to include private methods.
        # The eventual call resolves on self (the controller) so the private
        # visibility doesn't block invocation.
        csrf_token: respond_to?(:form_authenticity_token, true) ? form_authenticity_token : nil
      }
    end

    # AR replacements for the Sequel datasets the legacy code returned.
    # Both expressions are `ActiveRecord::Relation`s — same enumeration
    # contract Phlex views consume.
    # Projects the signed-in user is allowed to see. Admins see every
    # row in the projects table; everyone else only sees projects they
    # have a membership on (resolved by GitlabMembershipSync). Memoized
    # per request — every helper below routes through this. Falls back
    # to "all" when there's no current_user (test bootstrap, ad-hoc
    # rails runner). PR3 of the users-rollout chantier.
    def visible_project_paths
      @visible_project_paths ||=
        if !respond_to?(:current_user) || current_user.nil? || current_user.admin?
          Project.pluck(:gitlab_path)
        else
          current_user.visible_projects.pluck(:gitlab_path)
        end
    end

    def admin_or_no_session?
      !respond_to?(:current_user) || current_user.nil? || current_user.admin?
    end

    def issues_dataset
      admin_or_no_session? ? Issue.all : Issue.where(project_path: visible_project_paths)
    end

    def activity_events_dataset
      return ActivityEvent.all if admin_or_no_session?

      ActivityEvent.where(issue_id: issues_dataset.select(:id))
    end

    def status_counts
      issues_dataset.group(:status).count
    end

    def active_issues
      issues_dataset.where(status: Dashboard::ACTIVE_STATES).order(id: :desc).to_a
    end

    def issues_grouped_by_status(rows)
      rows.group_by { |r| r[:status] }
    end

    # Union of projects from the YAML config and projects that have any
    # tracked issue. Used by the /projects index so a configured-but-quiet
    # project still shows up before its first issue lands. Filtered by
    # visible_project_paths for non-admin users.
    def all_known_projects
      from_config = Array(app_config['projects']).map { |p| p['path'] }.compact
      from_db = issues_dataset.distinct.pluck(:project_path)
      union = (from_config + from_db).uniq.sort
      admin_or_no_session? ? union : (union & visible_project_paths)
    end

    # All projects that have at least one tracked issue, ordered by total
    # count desc. Returns [{path:, total:, active:, done:, error:}, ...].
    def project_breakdown
      paths = issues_dataset.distinct.pluck(:project_path).compact.sort
      paths.map { |path| project_stats(path) }
    end

    def project_stats(path)
      counts = Issue.where(project_path: path).group(:status).count
      total = counts.values.sum
      {
        path: path, total: total,
        active: Dashboard::ACTIVE_STATES.sum { |s| counts[s] || 0 },
        done: counts['done'] || 0,
        error: counts['error'] || 0
      }
    end

    def project_slug(project_path)
      project_path.to_s.gsub('/', '__')
    end

    def project_unslug(slug)
      slug.to_s.gsub('__', '/')
    end

    def project_for(project_path)
      Array(app_config['projects']).find { |p| p['path'] == project_path } || {}
    end

    # Counts used by the dashboard KPI cards.
    def dashboard_kpis
      counts = issues_dataset.group(:status).count
      active = Dashboard::ACTIVE_STATES.sum { |s| counts[s] || 0 }
      delivered_week = issues_dataset.where(status: 'done')
                                     .where('created_at >= ?', (Date.today - 7).to_s).count
      { active: active, pending: counts['pending'] || 0,
        errors: counts['error'] || 0,
        awaiting: counts['needs_clarification'] || 0,
        delivered_week: delivered_week }
    end

    # Activity counts per day for the past 7 days, oldest first — the data
    # behind the dashboard sparkline.
    #
    # Buckets by *local* calendar day in the configured display zone (see
    # #activity_time_zone), not by UTC day: created_at is stored in UTC, so an
    # event at 00:30 Paris time belongs to today's bar, not yesterday's.
    #
    # The 7 day boundaries are computed in Ruby (DST-correct via
    # ActiveSupport::TimeZone) and turned into UTC instants; a single
    # SUM(CASE …) range-counts each bucket. We deliberately avoid SQLite's
    # date(): a per-row UTC→local conversion in SQL can't follow DST, and
    # date() also returns NULL on the legacy " UTC"-suffixed rows. Comparing
    # the TEXT created_at against 'YYYY-MM-DD HH:MM:SS' UTC bounds is a correct
    # lexical range test for the clean, the fractional, and the suffixed format
    # alike (the date+time prefix dominates the ordering).
    def weekly_activity_counts
      bounds = weekly_activity_day_bounds
      row = activity_events_dataset
            .where('created_at >= ? AND created_at < ?', bounds.first, bounds.last)
            .pick(*weekly_activity_buckets(bounds))
      Array(row).map(&:to_i)
    end

    # The 8 UTC day boundaries ('YYYY-MM-DD HH:MM:SS') for the 7-day window,
    # local-midnight in #activity_time_zone converted to the UTC instants
    # actually stored in created_at. bounds[i]..bounds[i+1] is local day i.
    def weekly_activity_day_bounds
      zone = activity_time_zone
      (0..7).map { |offset| (zone.today - 6 + offset).in_time_zone(zone).utc.strftime('%F %T') }
    end

    # One SUM(CASE …) aggregate per day, range-counting created_at into the
    # bucket whose [start, next_start) UTC window contains it.
    def weekly_activity_buckets(bounds)
      conn = ActiveRecord::Base.connection
      (0..6).map do |i|
        Arel.sql("SUM(CASE WHEN created_at >= #{conn.quote(bounds[i])} " \
                 "AND created_at < #{conn.quote(bounds[i + 1])} THEN 1 ELSE 0 END)")
      end
    end

    # Display zone for day-bucketing the activity sparkline: the `web.timezone`
    # config key if set (e.g. "Europe/Paris"), else Rails' Time.zone, else UTC.
    # Lets the operator align the chart to their working day without changing
    # how AR stores timestamps (which stays UTC).
    def activity_time_zone
      name = app_config.dig('web', 'timezone')
      (name && ActiveSupport::TimeZone[name]) || Time.zone || ActiveSupport::TimeZone['UTC']
    end

    def gitlab_issue_url(issue)
      base = app_config['gitlab_url'].to_s.sub(%r{/+$}, '')
      return nil if base.empty? || issue[:project_path].to_s.empty?

      "#{base}/#{issue[:project_path]}/-/issues/#{issue[:issue_iid]}"
    end

    def gitlab_mr_url(issue)
      return issue[:mr_url] if issue[:mr_url] && !issue[:mr_url].empty?

      nil
    end

    def gitlab_project_url(project_path)
      base = app_config['gitlab_url'].to_s.sub(%r{/+$}, '')
      return nil if base.empty? || project_path.to_s.empty?

      "#{base}/#{project_path}"
    end

    PROJECT_DOT_COLORS = ['var(--accent-solid)', '#2A6FDB', '#1F8A7E', '#B57A12', '#C4413B'].freeze

    def project_dot_color(path)
      PROJECT_DOT_COLORS[path.to_s.bytes.sum % PROJECT_DOT_COLORS.size]
    end

    # Per-project counts used by the project page hero. Returns
    # {active:, errors:, done_month:, total:}. Distinct from
    # `project_stats` (above), which feeds the dashboard "Par projet"
    # table with a slightly different shape (path/total/active/done/error).
    def project_overview_stats(project_path)
      scope = Issue.where(project_path: project_path)
      counts = scope.group(:status).count
      since = (Date.today - 30).to_s
      {
        active: Dashboard::ACTIVE_STATES.sum { |s| counts[s] || 0 },
        errors: (counts['error'] || 0) + (counts['needs_clarification'] || 0),
        done_month: scope.where(status: 'done').where('created_at >= ?', since).count,
        total: counts.values.sum
      }
    end

    def find_issue(id)
      issues_dataset.find_by(id: Integer(id))
    end

    def h(text)
      CGI.escapeHTML(text.to_s)
    end

    def format_event(event)
      payload = event_payload(event)
      raw = case event[:kind]
            when 'transition'
              "#{payload['from']} → #{payload['to']} (#{payload['event']})"
            when 'danger_claude'
              payload['message'] || payload['key'].to_s
            else
              payload.empty? ? event[:kind] : payload.to_json
            end
      emojify(raw)
    end

    def event_payload(event)
      JSON.parse(event[:payload_json] || '{}')
    rescue JSON::ParserError
      {}
    end

    # Localized label for an ActivityEvent#kind. Falls back to the raw value
    # so unknown kinds remain visible rather than vanishing.
    def event_kind_label(kind)
      key = :"web_event_kind_#{kind}"
      Locales.lookup(web_locale, key) || Locales.lookup(:fr, key) || kind.to_s
    end

    # Localized label for a locale code stored on an issue. Returns the raw
    # code if no translation is registered.
    def locale_label(code)
      key = :"web_locale_#{code}"
      Locales.lookup(web_locale, key) || Locales.lookup(:fr, key) || code.to_s
    end

    # GitLab-style emoji shortcodes (`:warning:`, `:x:`, …) are interpreted
    # server-side on GitLab but reach the web UI verbatim. Replace the codes
    # we use in activity templates with their Unicode equivalents.
    EMOJI_SHORTCODES = {
      'arrow_right' => '➡️',
      'arrows_counterclockwise' => '🔄',
      'checkered_flag' => '🏁',
      'eyes' => '👀',
      'file_folder' => '📁',
      'gear' => '⚙️',
      'grey_question' => '❔',
      'hourglass_flowing_sand' => '⏳',
      'incoming_envelope' => '📨',
      'mag' => '🔍',
      'outbox_tray' => '📤',
      'pause_button' => '⏸️',
      'robot' => '🤖',
      'rocket' => '🚀',
      'speech_balloon' => '💬',
      'stop_sign' => '🛑',
      'thinking' => '🤔',
      'twisted_rightwards_arrows' => '🔀',
      'warning' => '⚠️',
      'white_check_mark' => '✅',
      'wrench' => '🔧',
      'x' => '❌'
    }.freeze

    def emojify(text)
      text.to_s.gsub(/:([a-z_]+):/) { |match| EMOJI_SHORTCODES[Regexp.last_match(1)] || match }
    end

    def permitted_events_for(issue)
      issue.aasm.events(permitted: true).map(&:name)
    end

    def screenshot_dir_for(issue)
      ScreenshotUploader.screenshot_dir(issue[:project_path], issue[:issue_iid])
    end

    def screenshot_files(issue)
      dir = screenshot_dir_for(issue)
      return [] unless File.directory?(dir)

      Dir.glob(File.join(dir, '*.png'))
    end
  end
end
