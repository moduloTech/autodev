# frozen_string_literal: true

require_relative 'helpers'
require_relative 'lifecycle'

module Web
  # Sinatra app exposing live views and actions over the autodev SQLite DB.
  class Server < Sinatra::Base
    extend Lifecycle

    set :root, File.expand_path('..', __dir__)
    set :views, File.expand_path('views', __dir__)
    set :public_folder, File.expand_path('public', __dir__)
    set :show_exceptions, false
    set :raise_errors, false
    set :logging, false
    set :static, false
    # Bind is always 127.0.0.1; host authorization adds no security and breaks Rack::Test.
    set :host_authorization, { permitted_hosts: [] }

    helpers Web::Helpers

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
      @counts = status_counts
      @active = active_issues
      @grouped = issues_grouped_by_status(@active)
      @by_project = project_breakdown
      erb :dashboard
    end

    get '/list/:status' do
      @status = params[:status]
      @issues = issues_dataset.where(status: @status).order(Sequel.desc(:id)).limit(500).all
      erb :list
    end

    get '/issues' do
      @per_page = per_page_for(params)
      @page = page_for(params)
      ds = filter_issues(params)
      @issues, @total, @total_pages, @page = paginate(ds, @page, @per_page)
      @filters = { q: params[:q], from: params[:from], to: params[:to] }
      erb :issues
    end

    get %r{/issues/(\d+)\.json} do |id|
      issue = find_issue(id)
      halt 404 unless issue

      content_type :json
      JSON.generate(issue.values)
    end

    get %r{/issues/(\d+)} do |id|
      @issue_model = find_issue(id)
      halt 404, 'Issue not found' unless @issue_model

      @issue = @issue_model.values
      @events = activity_events_dataset.where(issue_id: @issue[:id])
                                       .reverse_order(:created_at, :id).limit(200).all
      erb :issue_show
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
      @errored = issues_dataset.where(status: %w[error needs_clarification])
                               .or(Sequel.~(post_completion_error: nil))
                               .order(Sequel.desc(:id)).all
      erb :errors
    end

    get '/projects/:slug' do
      @project_path = project_unslug(params[:slug])
      @project_config = project_for(@project_path)
      @project_issues = issues_dataset.where(project_path: @project_path)
                                      .order(Sequel.desc(:id)).limit(100).all
      erb :project_show
    end
  end
end
