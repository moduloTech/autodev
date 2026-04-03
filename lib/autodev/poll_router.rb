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
    @project_path   = project_config['path']
    @use_labels     = Config.label_workflow?(project_config)
    @labels_todo    = project_config['labels_todo'] || []
    @label_mr       = project_config['label_mr']
    @label_done     = project_config['label_done']
    @label_blocked  = project_config['label_blocked']
  end

  # Route a single GitLab issue. Returns :next (skip to next issue) or :process (continue to legacy path).
  def route(gl_issue, client)
    return :process unless @use_labels

    gl_labels = gl_issue.labels || []
    existing = Issue.where(project_path: @project_path, issue_iid: gl_issue.iid).first

    has_todo    = gl_labels.intersect?(@labels_todo)
    has_mr      = gl_labels.include?(@label_mr)
    has_done    = gl_labels.include?(@label_done)
    has_blocked = gl_labels.include?(@label_blocked)

    if has_done && existing
      handle_done(gl_issue, existing, client)
      return :next
    end

    return :next if has_blocked

    if has_todo && existing&.status == 'over'
      handle_resume_todo(gl_issue, existing)
      return :next
    end

    if has_mr && existing&.status == 'over' && existing.mr_iid
      handle_resume_mr(gl_issue, existing, client)
      return :next
    end

    return :next unless has_todo

    :process
  end

  private

  def handle_done(gl_issue, existing, _client)
    unless existing.status == 'over'
      @logger.info("Issue ##{gl_issue.iid}: label_done detected, transitioning to over", project: @project_path)
    end
    worker_client = GitlabHelpers.build_gitlab_client(@config['gitlab_url'], @token)
    helper = MrFixer.new(client: worker_client, config: @config, project_config: @project_config, logger: @logger,
                         token: @token)
    helper.cleanup_labels(gl_issue.iid)
    existing.update(status: 'over', finished_at: Sequel.lit("datetime('now')")) unless existing.status == 'over'
  end

  def handle_resume_todo(gl_issue, existing)
    @logger.info("Issue ##{gl_issue.iid}: labels_todo detected on over issue, resuming full processing",
                 project: @project_path)
    return if @config['dry_run']

    existing.resume_todo! # over → pending
    existing.update(fix_round: 0, error_message: nil, finished_at: nil, started_at: nil)

    worker_client = GitlabHelpers.build_gitlab_client(@config['gitlab_url'], @token)
    processor = IssueProcessor.new(
      client: worker_client, config: @config, project_config: @project_config,
      logger: @logger, token: @token
    )
    @pool.enqueue?(issue_iid: existing.issue_iid) { processor.process(existing) }
    @logger.info("Enqueued resumed issue ##{gl_issue.iid}: #{gl_issue.title}", project: @project_path)
  end

  def handle_resume_mr(gl_issue, existing, client)
    mr_discussions = client.merge_request_discussions(@project_path, existing.mr_iid)
    has_unresolved = mr_discussions.any? do |d|
      next false unless d.notes&.any?

      resolvable = d.notes.select { |n| n.respond_to?(:resolvable) && n.resolvable }
      resolvable.any? && !resolvable.all? { |n| n.respond_to?(:resolved) && n.resolved }
    end

    if has_unresolved
      @logger.info("Issue ##{gl_issue.iid}: label_mr with unresolved discussions, resuming MR fix",
                   project: @project_path)
      return if @config['dry_run']

      existing.resume_mr! # over → fixing_discussions
      existing.update(fix_round: 0, pipeline_retrigger_count: 0)

      worker_client = GitlabHelpers.build_gitlab_client(@config['gitlab_url'], @token)
      fixer = MrFixer.new(
        client: worker_client, config: @config, project_config: @project_config,
        logger: @logger, token: @token
      )
      @pool.enqueue?(issue_iid: existing.issue_iid) { fixer.fix(existing) }
      @logger.info("Enqueued MR fix for issue ##{gl_issue.iid}", project: @project_path)
    end
  rescue Gitlab::Error::ResponseError => e
    @logger.error("Failed to check MR discussions for ##{gl_issue.iid}: #{e.message}", project: @project_path)
  end
end
