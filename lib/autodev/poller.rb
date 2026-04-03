# frozen_string_literal: true

require_relative 'poller/issue_handler'
require_relative 'poller/monitor_handler'

# Encapsulates the poll loop state and per-project polling logic.
class Poller
  include Poller::IssueHandler
  include Poller::MonitorHandler

  def initialize(config:, logger:, pastel:)
    @config = config
    @logger = logger
    @pastel = pastel
    @token = config['gitlab_token']
    @client = GitlabHelpers.build_gitlab_client(config['gitlab_url'], @token)
    @pool = WorkerPool.new(size: config['max_workers'], logger: logger)
    @shutdown = false
  end

  def run
    @pool.start
    @logger.debug("Worker pool started (#{@config['max_workers']} workers)")
    trap_signals
    poll_loop
    @logger.info('Shutting down workers...')
    @pool.shutdown
    @pool.cleanup
    @logger.info('autodev stopped.')
  end

  private

  def trap_signals
    %w[INT TERM].each { |sig| Signal.trap(sig) { @shutdown = true } }
  end

  def poll_loop
    loop do
      break if @shutdown

      @config['projects'].each do |project_config|
        break if @shutdown

        poll_project(project_config)
      end
      print_poll_summary
      break if @config['once']

      @config['poll_interval'].times { break if @shutdown; sleep 1 } # rubocop:disable Style/Semicolon
    end
  end

  def poll_project(project_config)
    path = project_config['path']
    @logger.debug("Polling #{path} for label '#{@config['trigger_label']}'...", project: path)
    poll_issues(project_config)
    return if @config['dry_run']

    poll_pipelines(project_config)
    poll_discussions(project_config)
    poll_retries(project_config)
  end

  def build_worker_client
    GitlabHelpers.build_gitlab_client(@config['gitlab_url'], @token)
  end

  def print_poll_summary
    active_issues = Database.db[:issues].exclude(status: 'over').all
    return if active_issues.empty?

    worker_map = @pool.assignments.invert
    $stdout.puts @pastel.dim("  --- #{active_issues.size} active issue(s) ---")
    active_issues.each { |row| print_issue_line(row, worker_map) }
  end

  def print_issue_line(row, worker_map)
    project_short = row[:project_path].to_s.split('/').last
    worker = worker_map[row[:issue_iid]]
    worker_tag = worker ? " [worker-#{worker}]" : ''
    $stdout.puts @pastel.dim(
      "  ##{row[:issue_iid]} #{row[:status].ljust(21)} " \
      "#{row[:issue_title]} (#{project_short})#{worker_tag}"
    )
  end
end
