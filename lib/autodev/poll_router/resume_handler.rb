# frozen_string_literal: true

class PollRouter
  # Handles resume transitions (over → pending or over → fixing_discussions).
  module ResumeHandler
    private

    def resume_todo_if_applicable(gl_issue, existing, flags)
      return unless flags[:todo] && existing&.status == 'over'

      handle_resume_todo(gl_issue, existing)
    end

    def resume_mr_if_applicable(gl_issue, existing, client, flags)
      return unless flags[:mr] && existing&.status == 'over' && existing.mr_iid

      handle_resume_mr(gl_issue, existing, client)
    end

    def handle_resume_todo(gl_issue, existing)
      @logger.info("Issue ##{gl_issue.iid}: labels_todo detected on over issue, resuming full processing",
                   project: @project_path)
      return if @config['dry_run']

      existing.resume_todo!
      existing.update(fix_round: 0, error_message: nil, finished_at: nil, started_at: nil)
      log_activity(existing, :resume_todo)
      enqueue_issue_processing(gl_issue, existing)
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
      log_activity(existing, :resume_mr)
      fixer = MrFixer.new(client: build_worker_client, config: @config,
                          project_config: @project_config, logger: @logger, token: @token)
      @pool.enqueue?(issue_iid: existing.issue_iid) { fixer.fix(existing) }
      @logger.info("Enqueued MR fix for issue ##{gl_issue.iid}", project: @project_path)
    end
  end
end
