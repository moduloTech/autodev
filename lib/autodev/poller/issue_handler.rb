# frozen_string_literal: true

class Poller
  # Issue discovery, creation, and enqueueing for the poll loop.
  module IssueHandler
    private

    def poll_issues(project_config)
      router = PollRouter.new(config: @config, project_config: project_config,
                              logger: @logger, token: @token, pool: @pool)
      fetch_and_route_issues(router, project_config)
    rescue StandardError => e
      @logger.error("Error polling #{project_config['path']}: #{e.class}: #{e.message}",
                    project: project_config['path'])
    end

    def fetch_and_route_issues(router, project_config)
      labels_todo = project_config['labels_todo'] || []
      GitlabHelpers.fetch_assignee_issues(@client, project_config['path'], labels_todo,
                                          GitlabHelpers.current_user_id(@client)).each do |gl_issue|
        break if @shutdown
        next if too_recent?(gl_issue)
        next if router.route(gl_issue, @client) == :next

        process_issue(gl_issue, project_config)
      end
    end

    def too_recent?(gl_issue)
      delay = @config['pickup_delay']
      return false if delay.zero?

      created = Time.parse(gl_issue.created_at.to_s)
      Time.now.utc - created < delay
    end

    def process_issue(gl_issue, project_config)
      path = project_config['path']
      existing = Issue.where(project_path: path, issue_iid: gl_issue.iid).first
      return if existing && skip_existing?(existing, gl_issue, path)
      return if exceeded_retries?(existing, project_config)
      return log_dry_run(gl_issue, path) if @config['dry_run']

      existing ||= find_or_create_issue(gl_issue, path)
      enqueue_issue(gl_issue, existing, project_config) if existing
    end

    def skip_existing?(existing, gl_issue, project_path)
      if existing.status == 'needs_clarification'
        return true unless clarification_received?(existing, gl_issue, project_path)
      elsif existing.status != 'pending'
        return true
      end
      false
    end

    def exceeded_retries?(existing, project_config)
      return false unless existing

      max_retries = (project_config['max_retries'] || @config['max_retries']).to_i
      existing.retry_count >= max_retries
    end

    def log_dry_run(gl_issue, path)
      @logger.info("[dry-run] Would process issue ##{gl_issue.iid}: #{gl_issue.title}", project: path)
    end

    def clarification_received?(existing, gl_issue, project_path)
      return false unless GitlabHelpers.clarification_answered?(
        @client, project_path, gl_issue.iid, existing.clarification_requested_at
      )

      @logger.info("Issue ##{gl_issue.iid}: clarification received, re-queuing", project: project_path)
      existing.clarification_received!
      existing.update(clarification_requested_at: nil, error_message: nil)
      ActivityLogger.post(ActivityLogger::Ctx.new(@client, project_path, @logger),
                          existing, :clarification_received)
      true
    end

    def find_or_create_issue(gl_issue, project_path)
      locale = LanguageDetector.detect(gl_issue.description.to_s)
      Issue.create(project_path: project_path, issue_iid: gl_issue.iid,
                   issue_title: gl_issue.title, status: 'pending',
                   issue_author_id: gl_issue.author&.id, locale: locale.to_s)
      Issue.where(project_path: project_path, issue_iid: gl_issue.iid).first
    rescue Sequel::UniqueConstraintViolation
      Issue.where(project_path: project_path, issue_iid: gl_issue.iid).first
    end

    def enqueue_issue(gl_issue, existing, project_config)
      worker_client = build_worker_client
      processor = IssueProcessor.new(client: worker_client, config: @config,
                                     project_config: project_config,
                                     logger: @logger, token: @token)
      @pool.enqueue?(issue_iid: existing.issue_iid) { processor.process(existing) }
      @logger.info("Enqueued issue ##{gl_issue.iid}: #{gl_issue.title}",
                   project: project_config['path'])
    end
  end
end
