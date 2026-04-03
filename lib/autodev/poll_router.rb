# frozen_string_literal: true

# Routes GitLab issues to the appropriate processor based on their labels and DB state.
# Extracts the label-driven routing logic from the polling loop in bin/autodev.
class PollRouter
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

  def resume_todo_if_applicable(gl_issue, existing, flags)
    return unless flags[:todo] && existing&.status == 'over'

    handle_resume_todo(gl_issue, existing)
  end

  def resume_mr_if_applicable(gl_issue, existing, client, flags)
    return unless flags[:mr] && existing&.status == 'over' && existing.mr_iid

    handle_resume_mr(gl_issue, existing, client)
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

  def handle_resume_todo(gl_issue, existing)
    @logger.info("Issue ##{gl_issue.iid}: labels_todo detected on over issue, resuming full processing",
                 project: @project_path)
    return if @config['dry_run']

    existing.resume_todo!
    existing.update(fix_round: 0, error_message: nil, finished_at: nil, started_at: nil)
    enqueue_issue_processing(gl_issue, existing)
  end

  def enqueue_issue_processing(gl_issue, existing)
    processor = IssueProcessor.new(client: build_worker_client, config: @config,
                                   project_config: @project_config, logger: @logger, token: @token)
    @pool.enqueue?(issue_iid: existing.issue_iid) { processor.process(existing) }
    @logger.info("Enqueued resumed issue ##{gl_issue.iid}: #{gl_issue.title}", project: @project_path)
  end

  def handle_resume_mr(gl_issue, existing, client)
    discussions = client.merge_request_discussions(@project_path, existing.mr_iid)
    return unless discussions.any? { |d| unresolved_discussion?(d) }

    @logger.info("Issue ##{gl_issue.iid}: label_mr with unresolved discussions, resuming MR fix",
                 project: @project_path)
    return if @config['dry_run']

    enqueue_mr_fix(gl_issue, existing)
  rescue Gitlab::Error::ResponseError => e
    @logger.error("Failed to check MR discussions for ##{gl_issue.iid}: #{e.message}", project: @project_path)
  end

  def unresolved_discussion?(discussion)
    resolvable = (discussion.notes || []).select { |n| n.respond_to?(:resolvable) && n.resolvable }
    resolvable.any? && resolvable.none? { |n| n.respond_to?(:resolved) && n.resolved }
  end

  def enqueue_mr_fix(gl_issue, existing)
    existing.resume_mr!
    existing.update(fix_round: 0, pipeline_retrigger_count: 0)
    fixer = MrFixer.new(client: build_worker_client, config: @config,
                        project_config: @project_config, logger: @logger, token: @token)
    @pool.enqueue?(issue_iid: existing.issue_iid) { fixer.fix(existing) }
    @logger.info("Enqueued MR fix for issue ##{gl_issue.iid}", project: @project_path)
  end

  def build_worker_client
    GitlabHelpers.build_gitlab_client(@config['gitlab_url'], @token)
  end
end
