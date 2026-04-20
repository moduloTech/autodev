# frozen_string_literal: true

require_relative 'unassignment_handler'

class Poller
  # Pipeline monitoring, discussion fixes, and error retry for the poll loop.
  module MonitorHandler
    include UnassignmentHandler

    private

    def poll_pipelines(project_config)
      path = project_config['path']
      Issue.where(project_path: path, status: 'checking_pipeline')
           .exclude(mr_iid: nil).all.each do |issue|
        break if @shutdown

        enqueue_pipeline_check(issue, project_config)
      end
    rescue StandardError => e
      @logger.error("Error polling pipeline monitoring for #{project_config['path']}: #{e.message}",
                    project: project_config['path'])
    end

    def enqueue_pipeline_check(issue, project_config)
      monitor = PipelineMonitor.new(client: build_worker_client, config: @config,
                                    project_config: project_config,
                                    logger: @logger, token: @token)
      @pool.enqueue?(issue_iid: issue.issue_iid) { monitor.check(issue) }
      @logger.info("Enqueued pipeline check for issue ##{issue.issue_iid} (MR !#{issue.mr_iid})",
                   project: project_config['path'])
    end

    def poll_discussions(project_config)
      path = project_config['path']
      Issue.where(project_path: path, status: 'fixing_discussions')
           .exclude(mr_iid: nil).all.each do |issue|
        break if @shutdown

        enqueue_discussion_fix(issue, project_config)
      end
    rescue StandardError => e
      @logger.error("Error polling discussion fixes for #{project_config['path']}: #{e.message}",
                    project: project_config['path'])
    end

    def enqueue_discussion_fix(issue, project_config)
      fixer = MrFixer.new(client: build_worker_client, config: @config,
                          project_config: project_config,
                          logger: @logger, token: @token)
      @pool.enqueue?(issue_iid: issue.issue_iid) { fixer.fix(issue) }
      @logger.info("Enqueued discussion fix for issue ##{issue.issue_iid} (round #{issue.fix_round + 1})",
                   project: project_config['path'])
    end

    def poll_retries(project_config)
      path = project_config['path']
      retryable = fetch_retryable(project_config)
      return if retryable.empty?

      max = (project_config['max_retries'] || @config['max_retries']).to_i
      retry_helper = build_retry_helper(project_config) if Config.label_workflow?(project_config)
      retryable.each { |issue| retry_single_issue(issue, retry_helper, path, max) }
    rescue StandardError => e
      @logger.error("Error retrying issues for #{path}: #{e.message}", project: path)
    end

    def fetch_retryable(project_config)
      max_retries = (project_config['max_retries'] || @config['max_retries']).to_i
      Issue.where(project_path: project_config['path'], status: 'error')
           .where { retry_count < max_retries }
           .where { Sequel.lit("next_retry_at IS NOT NULL AND next_retry_at <= datetime('now')") }.all
    end

    def build_retry_helper(project_config)
      MrFixer.new(client: build_worker_client, config: @config,
                  project_config: project_config, logger: @logger, token: @token)
    end

    def retry_single_issue(issue, retry_helper, project_path, max_retries)
      has_mr = !issue.mr_iid.nil?
      has_mr ? issue.retry_pipeline! : issue.retry_processing!
      issue.update(error_message: nil, started_at: nil)
      restore_labels(issue, retry_helper, has_mr, project_path)
      target = has_mr ? 'checking_pipeline' : 'pending'
      @logger.info("Issue ##{issue.issue_iid} retried → #{target} (attempt #{issue.retry_count + 1})",
                   project: project_path)
      log_retry_activity(issue, project_path, max_retries)
    rescue AASM::InvalidTransition => e
      @logger.error("Could not retry issue ##{issue.issue_iid}: #{e.message}", project: project_path)
    end

    def log_retry_activity(issue, project_path, max_retries)
      ctx = ActivityLogger::Ctx.new(@client, project_path, @logger)
      ActivityLogger.post(ctx, issue, :retry, attempt: issue.retry_count + 1, max: max_retries)
    end

    def restore_labels(issue, retry_helper, has_mr, project_path)
      return unless retry_helper

      if has_mr
        retry_helper.apply_label_done(issue.issue_iid)
      else
        retry_helper.apply_label_doing(issue.issue_iid)
      end
    rescue StandardError => e
      @logger.error("Failed to restore labels for ##{issue.issue_iid}: #{e.message}",
                    project: project_path)
    end
  end
end
