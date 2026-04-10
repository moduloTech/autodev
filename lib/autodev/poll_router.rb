# frozen_string_literal: true

require_relative 'poll_router/resume_handler'

# Routes GitLab issues to the appropriate processor based on their labels and DB state.
# Extracts the label-driven routing logic from the polling loop in bin/autodev.
class PollRouter
  include ResumeHandler

  def initialize(config:, project_config:, logger:, token:, pool:)
    @config         = config
    @project_config = project_config
    @logger         = logger
    @token          = token
    @pool           = pool
    init_project_settings(project_config)
  end

  # Route a single GitLab issue. Returns :next (skip to next issue) or :process (continue to processing).
  def route(gl_issue, client)
    return :process unless @use_labels

    @route_client = client
    existing = Issue.where(project_path: @project_path, issue_iid: gl_issue.iid).first
    route_by_state(gl_issue, existing)
  end

  private

  def init_project_settings(project_config)
    @project_path = project_config['path']
    @use_labels   = Config.label_workflow?(project_config)
  end

  def route_by_state(gl_issue, existing)
    return :process unless existing

    if existing.status == 'done'
      handle_reenter(gl_issue, existing)
      return :next
    end

    existing.status == 'pending' ? :process : :next
  end

  def enqueue_issue_processing(gl_issue, existing)
    processor = IssueProcessor.new(client: build_worker_client, config: @config,
                                   project_config: @project_config, logger: @logger, token: @token)
    @pool.enqueue?(issue_iid: existing.issue_iid) { processor.process(existing) }
    @logger.info("Enqueued resumed issue ##{gl_issue.iid}: #{gl_issue.title}", project: @project_path)
  end

  def build_worker_client
    GitlabHelpers.build_gitlab_client(@config['gitlab_url'], @token)
  end

  def log_activity(issue, key)
    ActivityLogger.post(ActivityLogger::Ctx.new(@route_client, @project_path, @logger), issue, key)
  end
end
