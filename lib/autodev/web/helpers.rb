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
      Web::Server.app_config || {}
    end

    def issues_dataset
      Database.db[:issues]
    end

    def activity_events_dataset
      Database.db[:activity_events]
    end

    def status_counts
      issues_dataset.group_and_count(:status).to_hash(:status, :count)
    end

    def active_issues
      issues_dataset.where(status: Dashboard::ACTIVE_STATES).order(Sequel.desc(:id)).all
    end

    def issues_grouped_by_status(rows)
      rows.group_by { |r| r[:status] }
    end

    # All projects that have at least one tracked issue, ordered by total
    # count desc. Returns [{path:, total:, active:, done:, error:}, ...].
    def project_breakdown
      rows = issues_dataset.select_group(:project_path).select_append { count.function.* }.all
      paths = rows.map { |r| r[:project_path] }.uniq.sort
      paths.map { |path| project_stats(path) }
    end

    def project_stats(path)
      ds = issues_dataset.where(project_path: path)
      counts = ds.group_and_count(:status).to_hash(:status, :count)
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
      counts = issues_dataset.group_and_count(:status).to_hash(:status, :count)
      active = Dashboard::ACTIVE_STATES.sum { |s| counts[s] || 0 }
      delivered_week = issues_dataset.where(status: 'done')
                                     .where { created_at >= (Date.today - 7).to_s }.count
      { active: active, errors: counts['error'] || 0,
        awaiting: counts['needs_clarification'] || 0,
        delivered_week: delivered_week }
    end

    # Activity counts per day for the past 7 days, oldest first.
    # Used by the dashboard sparkline.
    def weekly_activity_counts # rubocop:disable Metrics/AbcSize
      since = (Date.today - 6).to_s
      rows = activity_events_dataset
             .where { created_at >= since }
             .select_group(Sequel.function(:date, :created_at).as(:day))
             .select_append { count.function.* }
             .to_hash(:day, :count)
      (0..6).map { |offset| rows[(Date.today - 6 + offset).to_s] || 0 }
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

    def find_issue(id)
      Issue[Integer(id)]
    end

    def h(text)
      CGI.escapeHTML(text.to_s)
    end

    def format_event(event)
      payload = event_payload(event)
      case event[:kind]
      when 'transition'
        "#{payload['from']} → #{payload['to']} (#{payload['event']})"
      when 'danger_claude'
        payload['message'] || payload['key'].to_s
      else
        payload.empty? ? event[:kind] : payload.to_json
      end
    end

    def event_payload(event)
      JSON.parse(event[:payload_json] || '{}')
    rescue JSON::ParserError
      {}
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
