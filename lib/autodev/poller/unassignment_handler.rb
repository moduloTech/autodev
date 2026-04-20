# frozen_string_literal: true

class Poller
  # Detects unassignment and triggers post-completion for done issues.
  module UnassignmentHandler
    private

    def poll_unassignment(project_config)
      path = project_config['path']
      active_statuses = %w[cloning checking_spec implementing committing pushing creating_mr
                           checking_pipeline reviewing fixing_discussions fixing_pipeline]
      # .all materializes the result and releases the DB connection before
      # the loop body runs external GitLab calls per issue — important when
      # the Sequel pool is single-connection (see lib/autodev/database.rb).
      Issue.where(project_path: path, status: active_statuses).all.each do |issue|
        break if @shutdown

        check_still_assigned(issue, project_config)
      end
    rescue StandardError => e
      @logger.error("Error checking unassignment for #{path}: #{e.message}", project: path)
    end

    def check_still_assigned(issue, project_config)
      return if still_assigned?(issue, project_config)

      path = project_config['path']
      @logger.info("Issue ##{issue.issue_iid}: no longer assigned, transitioning to done", project: path)
      issue.update(status: 'done', finished_at: Sequel.lit("datetime('now')"))
      ActivityLogger.post(ActivityLogger::Ctx.new(@client, path, @logger), issue, :unassigned_stop)
    rescue Gitlab::Error::ResponseError => e
      @logger.error("Failed to check assignment for ##{issue.issue_iid}: #{e.message}",
                    project: project_config['path'])
    end

    def poll_done_unassigned(project_config)
      pc_cmd = project_config['post_completion']
      return unless pc_cmd.is_a?(Array) && pc_cmd.any?

      path = project_config['path']
      Issue.where(project_path: path, status: 'done').exclude(mr_iid: nil).all.each do |issue|
        break if @shutdown

        check_post_completion_needed(issue, project_config)
      end
    rescue StandardError => e
      @logger.error("Error checking post-completion for #{path}: #{e.message}", project: path)
    end

    def check_post_completion_needed(issue, project_config)
      return if still_assigned?(issue, project_config)
      return if mr_closed_or_merged?(issue, project_config)

      enqueue_post_completion(issue, project_config)
    rescue Gitlab::Error::ResponseError => e
      @logger.error("Failed to check post-completion for ##{issue.issue_iid}: #{e.message}",
                    project: project_config['path'])
    end

    def still_assigned?(issue, project_config)
      gl_issue = @client.issue(project_config['path'], issue.issue_iid)
      (gl_issue.assignees || []).any? { |a| a.id == GitlabHelpers.current_user_id(@client) }
    end

    def mr_closed_or_merged?(issue, project_config)
      mr = @client.merge_request(project_config['path'], issue.mr_iid)
      %w[merged closed].include?(mr.state)
    end

    def enqueue_post_completion(issue, project_config)
      monitor = build_pipeline_monitor(project_config)
      @pool.enqueue?(issue_iid: issue.issue_iid) do
        run_post_completion_task(issue, project_config, monitor)
      end
      @logger.info("Enqueued post-completion for issue ##{issue.issue_iid}",
                   project: project_config['path'])
    end

    def run_post_completion_task(issue, project_config, monitor)
      issue.start_post_completion!
      ctx = ActivityLogger::Ctx.new(build_worker_client, project_config['path'], @logger)
      ActivityLogger.post(ctx, issue, :post_completion)
      monitor.run_post_completion(issue, project_config['post_completion'])
      issue.post_completion_done!
    end

    def build_pipeline_monitor(project_config)
      PipelineMonitor.new(client: build_worker_client, config: @config,
                          project_config: project_config, logger: @logger, token: @token)
    end
  end
end
