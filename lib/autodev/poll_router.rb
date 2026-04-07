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

  # Route a single GitLab issue. Returns :next (skip to next issue) or :process (continue to legacy path).
  def route(gl_issue, client)
    return :process unless @use_labels

    @route_client = client
    existing = Issue.where(project_path: @project_path, issue_iid: gl_issue.iid).first
    route_by_labels(gl_issue, existing, client, extract_label_flags(gl_issue))
  end

  private

  def init_project_settings(project_config)
    @project_path  = project_config['path']
    @use_labels    = Config.label_workflow?(project_config)
    @labels_todo   = project_config['labels_todo'] || []
    @label_mr      = project_config['label_mr']
    @label_done    = project_config['label_done']
    @label_blocked = project_config['label_blocked']
  end

  def extract_label_flags(gl_issue)
    gl_labels = gl_issue.labels || []
    { todo: gl_labels.intersect?(@labels_todo), mr: gl_labels.include?(@label_mr),
      done: gl_labels.include?(@label_done), blocked: gl_labels.include?(@label_blocked) }
  end

  def route_by_labels(gl_issue, existing, client, flags)
    if flags[:done] && existing
      handle_done(gl_issue, existing)
      return :next
    end
    return :next if flags[:blocked]
    return :next if resume_todo_if_applicable(gl_issue, existing, flags)
    return :next if resume_mr_if_applicable(gl_issue, existing, client, flags)
    return :next unless processable_labels?(existing, flags)

    :process
  end

  def processable_labels?(existing, flags)
    flags[:todo] || (flags[:mr] && (existing.nil? || existing.status == 'pending'))
  end

  def handle_done(gl_issue, existing)
    unless existing.status == 'over'
      @logger.info("Issue ##{gl_issue.iid}: label_done detected, transitioning to over",
                   project: @project_path)
    end
    helper = MrFixer.new(client: build_worker_client, config: @config,
                         project_config: @project_config, logger: @logger, token: @token)
    helper.cleanup_labels(gl_issue.iid)
    existing.update(status: 'over', finished_at: Sequel.lit("datetime('now')")) unless existing.status == 'over'
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
