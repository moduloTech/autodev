# frozen_string_literal: true

require_relative 'helpers'
require_relative 'lifecycle'

module Web
  # Sinatra app exposing live views and actions over the autodev SQLite DB.
  class Server < Sinatra::Base # rubocop:disable Metrics/ClassLength
    extend Lifecycle

    set :root, File.expand_path('..', __dir__)
    set :public_folder, File.expand_path('public', __dir__)
    set :show_exceptions, false
    set :raise_errors, false
    set :logging, false
    set :static, false
    # Bind is always 127.0.0.1; host authorization adds no security and breaks Rack::Test.
    set :host_authorization, { permitted_hosts: [] }

    helpers Web::Helpers

    helpers do
      # Common kwargs passed to every Phlex view: locale + the path the user
      # came from (for the locale switcher's `back=` query).
      def view_context
        { locale: web_locale, request_path: request.fullpath }
      end
    end

    # Per-browser locale override (cookie). Falls through to the
    # config-defined locale when no cookie is set.
    get '/locale/:lang' do
      apply_locale_cookie!(params[:lang])
      redirect safe_back_path(params[:back])
    end

    # Vendored Turbo (no CDN). Served only via this explicit route.
    get '/assets/turbo.js' do
      content_type 'application/javascript'
      send_file File.join(settings.public_folder, 'turbo.js')
    end

    # Server-Sent Events endpoint. One open connection per browser tab.
    # Each event published to Web::EventBus is encoded as a single SSE frame.
    get '/stream' do
      content_type 'text/event-stream'
      headers 'Cache-Control' => 'no-cache', 'X-Accel-Buffering' => 'no'
      stream(:keep_open) do |out|
        queue = Web::EventBus.subscribe
        loop do
          event = queue.pop
          break if event == Web::EventBus::SHUTDOWN_SENTINEL

          out << format_sse(event)
        end
      ensure
        Web::EventBus.unsubscribe(queue) if queue
        out.close unless out.closed?
      end
    end

    get '/' do
      active = active_issues
      Web::Views::Dashboard.new(
        counts: status_counts, active: active,
        grouped: issues_grouped_by_status(active),
        by_project: project_breakdown, **view_context
      ).call
    end

    get '/list/:status' do
      issues = issues_dataset.where(status: params[:status]).order(Sequel.desc(:id)).limit(500).all
      Web::Views::List.new(status: params[:status], issues: issues, **view_context).call
    end

    get '/issues' do
      per_page = per_page_for(params)
      page = page_for(params)
      ds = filter_issues(params)
      issues, total, total_pages, page = paginate(ds, page, per_page)
      Web::Views::Issues.new(
        issues: issues, total: total, total_pages: total_pages,
        page: page, per_page: per_page,
        filters: { q: params[:q], from: params[:from], to: params[:to] },
        **view_context
      ).call
    end

    get %r{/issues/(\d+)\.json} do |id|
      issue = find_issue(id)
      halt 404 unless issue

      content_type :json
      JSON.generate(issue.values)
    end

    get %r{/issues/(\d+)} do |id|
      issue_model = find_issue(id)
      halt 404, 'Issue not found' unless issue_model

      issue = issue_model.values
      events = activity_events_dataset.where(issue_id: issue[:id])
                                      .reverse_order(:created_at, :id).limit(200).all
      Web::Views::IssueShow.new(issue: issue, issue_model: issue_model, events: events, **view_context).call
    end

    post %r{/issues/(\d+)/reset} do |id|
      issue = find_issue(id)
      halt 404 unless issue

      issues_dataset.where(id: issue.id).update(
        status: 'pending', retry_count: 0, error_message: nil,
        next_retry_at: nil, started_at: nil
      )
      redirect "/issues/#{issue.id}"
    end

    post %r{/issues/(\d+)/transition} do |id|
      issue = find_issue(id)
      halt 404 unless issue

      event = params[:event].to_s
      unless permitted_events_for(issue).include?(event.to_sym)
        halt 422, "Event '#{event}' not permitted from #{issue.status}"
      end

      issue.send("#{event}!")
      redirect "/issues/#{issue.id}"
    end

    get '/errors' do
      errored = issues_dataset.where(status: %w[error needs_clarification])
                              .or(Sequel.~(post_completion_error: nil))
                              .order(Sequel.desc(:id)).all
      Web::Views::Errors.new(errored: errored, **view_context).call
    end

    get '/projects/:slug' do
      project_path = project_unslug(params[:slug])
      Web::Views::ProjectShow.new(
        project_path: project_path,
        project_config: project_for(project_path),
        project_issues: issues_dataset.where(project_path: project_path)
                        .order(Sequel.desc(:id)).limit(100).all,
        **view_context
      ).call
    end
  end
end
