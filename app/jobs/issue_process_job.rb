# frozen_string_literal: true

# Generic per-issue executor for the Solid Queue migration of the poller
# (railsification step 5). Dispatched by `Autodev::PollDispatcher` for every
# work item the recurring `AutodevPollJob` discovers.
#
# The `action` argument selects which legacy worker class handles the row:
#   :process           → IssueProcessor.process    (pending → done lifecycle)
#   :check_pipeline    → PipelineMonitor.check     (checking_pipeline rows)
#   :fix_discussions   → MrFixer.fix               (fixing_discussions rows)
#   :post_completion   → post-completion sequence  (done + unassigned + pc cmd)
#   :retry_errored     → retry path for error rows (clears backoff + re-enters)
#   :retry_stuck       → re-enqueue a stuck pending row
#
# Concurrency: at most one execution per (project_path, issue_iid) at a
# time. The N=3 global cap comes from queue.yml's worker `threads` setting,
# not from per-key concurrency.
class IssueProcessJob < ApplicationJob
  queue_as :default

  limits_concurrency to: 1,
                     key: ->(project_path, issue_iid, *_) { "issue-#{project_path}-#{issue_iid}" },
                     duration: 1.hour

  ACTIONS = %i[process check_pipeline fix_discussions post_completion retry_errored retry_stuck].freeze

  def perform(project_path, issue_iid, action)
    action = action.to_sym
    raise ArgumentError, "unknown action #{action.inspect}" unless ACTIONS.include?(action)

    config = ::Config.load
    project_config = lookup_project_config(config, project_path)
    return unless project_config

    issue = ::Issue.where(project_path: project_path, issue_iid: issue_iid).first
    return unless issue

    public_send("perform_#{action}", issue, config, project_config)
  end

  private

  def lookup_project_config(config, project_path)
    Array(config['projects']).find { |p| p['path'] == project_path }
  end

  def build_client(config)
    ::GitlabHelpers.build_gitlab_client(config['gitlab_url'], config['gitlab_token'])
  end

  def worker_kwargs(config, project_config)
    {
      client: build_client(config),
      config: config,
      project_config: project_config,
      logger: logger,
      token: config['gitlab_token']
    }
  end

  public

  def perform_process(issue, config, project_config)
    ::IssueProcessor.new(**worker_kwargs(config, project_config)).process(issue)
  end

  def perform_check_pipeline(issue, config, project_config)
    ::PipelineMonitor.new(**worker_kwargs(config, project_config)).check(issue)
  end

  def perform_fix_discussions(issue, config, project_config)
    ::MrFixer.new(**worker_kwargs(config, project_config)).fix(issue)
  end

  def perform_post_completion(issue, config, project_config)
    monitor = ::PipelineMonitor.new(**worker_kwargs(config, project_config))
    issue.start_post_completion!
    ctx = ::ActivityLogger::Ctx.new(build_client(config), project_config['path'], logger)
    ::ActivityLogger.post(ctx, issue, :post_completion)
    monitor.run_post_completion(issue, project_config['post_completion'])
    issue.post_completion_done!
  end

  def perform_retry_errored(issue, config, project_config)
    has_mr = !issue.mr_iid.nil?
    has_mr ? issue.retry_pipeline! : issue.retry_processing!
    issue.update(error_message: nil, started_at: nil)
    restore_labels(issue, config, project_config, has_mr)
    log_retry_activity(issue, config, project_config)
  end

  def perform_retry_stuck(issue, config, project_config)
    issue.update(next_retry_at: nil)
    log_retry_activity(issue, config, project_config)
    ::IssueProcessor.new(**worker_kwargs(config, project_config)).process(issue)
  end

  private

  def restore_labels(issue, config, project_config, has_mr)
    return unless ::Config.label_workflow?(project_config)

    helper = ::MrFixer.new(**worker_kwargs(config, project_config))
    has_mr ? helper.apply_label_done(issue.issue_iid) : helper.apply_label_doing(issue.issue_iid)
  rescue StandardError => e
    logger.error("Failed to restore labels for ##{issue.issue_iid}: #{e.class}: #{e.message}")
  end

  def log_retry_activity(issue, config, project_config)
    max = (project_config['max_retries'] || config['max_retries']).to_i
    ctx = ::ActivityLogger::Ctx.new(build_client(config), project_config['path'], logger)
    ::ActivityLogger.post(ctx, issue, :retry, attempt: issue.retry_count + 1, max: max)
  end
end
