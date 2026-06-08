# frozen_string_literal: true

module Autodev
  # Per-project polling cycle that mirrors what `Poller#poll_project` does in
  # the legacy threaded poller, except it enqueues IssueProcessJobs onto Solid
  # Queue instead of WorkerPool closures.
  #
  # Discovery passes (GitLab queries + Sequel queries against the `issues`
  # table) run inline inside `AutodevPollJob`. The processing itself happens
  # asynchronously: each discovered work item produces an
  # `IssueProcessJob.perform_later(project_path, issue_iid, action)` call,
  # and Solid Queue's queue.yml-configured worker pool runs them with
  # configurable concurrency (default 3, matching legacy `max_workers`).
  #
  # The Sequel models (`Issue`, `ActivityEvent`) are dynamically defined by
  # `Database.build_model!` which the legacy_sinatra initializer runs at
  # boot — so this class can call `::Issue.where(...)` exactly like the
  # legacy handlers do.
  class PollDispatcher # rubocop:disable Metrics/ClassLength
    ACTIVE_STATUSES = %w[cloning checking_spec implementing committing pushing creating_mr
                         checking_pipeline reviewing fixing_discussions fixing_pipeline].freeze

    # PollRouter's contract expects a `pool` arg with an `enqueue?` method. In
    # the Solid Queue world the router still routes (returns :next vs
    # :continue) but the actual enqueue happens through `process_issue`
    # below, never via the pool object — so we hand it a no-op. PollRouter
    # also occasionally enqueues a re-implementation cycle itself via the
    # pool; for those branches we forward to the job. Block content runs
    # inline so the router's reentry / reimplementation branches still
    # execute their AASM transitions; this goes away at step 6 when
    # WorkerPool is deleted and PollRouter is refactored to enqueue jobs
    # directly.
    NullPool = Module.new do
      module_function

      def enqueue?(issue_iid:, &block) # rubocop:disable Lint/UnusedMethodArgument
        block&.call
        true
      end
    end

    def initialize(config:, project_config:, logger:)
      @config = config
      @project_config = project_config
      @logger = logger
      @path = project_config['path']
      @token = config['gitlab_token']
      @client = ::GitlabHelpers.build_gitlab_client(config['gitlab_url'], @token)
    end

    def dispatch
      @logger.debug("[poll_dispatcher] #{@path}", project: @path)
      dispatch_new_issues
      return if @config['dry_run']

      dispatch_existing
    rescue StandardError => e
      @logger.error("[poll_dispatcher] #{@path} failed: #{e.class}: #{e.message}",
                    project: @path)
    end

    private

    def dispatch_existing
      dispatch_pipelines
      dispatch_discussions
      dispatch_unassignment
      dispatch_done_unassigned
      dispatch_retries
    end

    # === poll_issues equivalent ===

    def dispatch_new_issues
      labels_todo = @project_config['labels_todo'] || []
      ::GitlabHelpers.fetch_assignee_issues(
        @client, @path, labels_todo, ::GitlabHelpers.current_user_id(@client)
      ).each do |gl_issue|
        next if too_recent?(gl_issue)

        router = ::PollRouter.new(config: @config, project_config: @project_config,
                                  logger: @logger, token: @token, pool: NullPool)
        next if router.route(gl_issue, @client) == :next

        process_issue(gl_issue)
      end
    end

    def too_recent?(gl_issue)
      delay = @config['pickup_delay'].to_i
      return false if delay.zero?

      Time.now.utc - Time.parse(gl_issue.created_at.to_s) < delay
    end

    def process_issue(gl_issue)
      existing = ::Issue.where(project_path: @path, issue_iid: gl_issue.iid).first
      return if existing && skip_existing?(existing, gl_issue)
      return if exceeded_retries?(existing)
      return log_dry_run(gl_issue) if @config['dry_run']

      existing ||= find_or_create_issue(gl_issue)
      return unless existing

      IssueProcessJob.perform_later(@path, existing.issue_iid, :process)
      @logger.info("Enqueued issue ##{gl_issue.iid}: #{gl_issue.title}", project: @path)
    end

    def skip_existing?(existing, gl_issue)
      if existing.status == 'needs_clarification'
        return true unless clarification_received?(existing, gl_issue)
      elsif existing.status != 'pending'
        return true
      end
      false
    end

    def exceeded_retries?(existing)
      return false unless existing

      max_retries = (@project_config['max_retries'] || @config['max_retries']).to_i
      existing.retry_count >= max_retries
    end

    def log_dry_run(gl_issue)
      @logger.info("[dry-run] Would process issue ##{gl_issue.iid}: #{gl_issue.title}", project: @path)
    end

    def clarification_received?(existing, gl_issue)
      return false unless ::GitlabHelpers.clarification_answered?(
        @client, @path, gl_issue.iid, existing.clarification_requested_at
      )

      @logger.info("Issue ##{gl_issue.iid}: clarification received, re-queuing", project: @path)
      existing.clarification_received!
      existing.update(clarification_requested_at: nil, error_message: nil)
      ::ActivityLogger.post(::ActivityLogger::Ctx.new(@client, @path, @logger),
                            existing, :clarification_received)
      true
    end

    def find_or_create_issue(gl_issue)
      locale = ::LanguageDetector.detect(gl_issue.description.to_s)
      ::Issue.create(project_path: @path, issue_iid: gl_issue.iid,
                     issue_title: gl_issue.title, status: 'pending',
                     issue_author_id: gl_issue.author&.id, locale: locale.to_s)
      ::Issue.where(project_path: @path, issue_iid: gl_issue.iid).first
    rescue ActiveRecord::RecordNotUnique
      ::Issue.where(project_path: @path, issue_iid: gl_issue.iid).first
    end

    # === poll_pipelines / poll_discussions equivalents ===

    def dispatch_pipelines
      ::Issue.where(project_path: @path, status: 'checking_pipeline')
             .where.not(mr_iid: nil).find_each do |issue|
        IssueProcessJob.perform_later(@path, issue.issue_iid, :check_pipeline)
        @logger.info("Enqueued pipeline check for issue ##{issue.issue_iid} (MR !#{issue.mr_iid})",
                     project: @path)
      end
    end

    def dispatch_discussions
      ::Issue.where(project_path: @path, status: 'fixing_discussions')
             .where.not(mr_iid: nil).find_each do |issue|
        IssueProcessJob.perform_later(@path, issue.issue_iid, :fix_discussions)
        @logger.info("Enqueued discussion fix for issue ##{issue.issue_iid} (round #{issue.fix_round + 1})",
                     project: @path)
      end
    end

    # === poll_unassignment equivalent (inline — DB-only, no queue overhead) ===

    def dispatch_unassignment
      ::Issue.where(project_path: @path, status: ACTIVE_STATUSES).find_each do |issue|
        check_still_assigned(issue)
      end
    end

    def check_still_assigned(issue)
      return if still_assigned?(issue)

      @logger.info("Issue ##{issue.issue_iid}: no longer assigned, transitioning to done",
                   project: @path)
      issue.update(status: 'done', finished_at: Time.current)
      ::ActivityLogger.post(::ActivityLogger::Ctx.new(@client, @path, @logger),
                            issue, :unassigned_stop)
    rescue ::Gitlab::Error::ResponseError => e
      @logger.error("Failed to check assignment for ##{issue.issue_iid}: #{e.message}",
                    project: @path)
    end

    def dispatch_done_unassigned
      pc_cmd = @project_config['post_completion']
      return unless pc_cmd.is_a?(Array) && pc_cmd.any?

      ::Issue.where(project_path: @path, status: 'done').where.not(mr_iid: nil).find_each do |issue|
        check_post_completion_needed(issue)
      end
    end

    def check_post_completion_needed(issue)
      return if still_assigned?(issue)
      return if mr_closed_or_merged?(issue)

      IssueProcessJob.perform_later(@path, issue.issue_iid, :post_completion)
      @logger.info("Enqueued post-completion for issue ##{issue.issue_iid}", project: @path)
    rescue ::Gitlab::Error::ResponseError => e
      @logger.error("Failed to check post-completion for ##{issue.issue_iid}: #{e.message}",
                    project: @path)
    end

    def still_assigned?(issue)
      gl_issue = @client.issue(@path, issue.issue_iid)
      (gl_issue.assignees || []).any? { |a| a.id == ::GitlabHelpers.current_user_id(@client) }
    end

    def mr_closed_or_merged?(issue)
      mr = @client.merge_request(@path, issue.mr_iid)
      %w[merged closed].include?(mr.state)
    end

    # === poll_retries equivalent ===

    def dispatch_retries
      retryable = fetch_retryable
      return if retryable.empty?

      retryable.each { |issue| enqueue_retry(issue) }
    end

    def fetch_retryable
      max_retries = (@project_config['max_retries'] || @config['max_retries']).to_i
      ::Issue.where(project_path: @path)
             .where(status: %w[error pending])
             .where('retry_count < ?', max_retries)
             .where("next_retry_at IS NOT NULL AND next_retry_at <= datetime('now')")
             .to_a
    end

    def enqueue_retry(issue)
      action = issue.status == 'pending' ? :retry_stuck : :retry_errored
      IssueProcessJob.perform_later(@path, issue.issue_iid, action)
      @logger.info("Enqueued retry (#{action}) for issue ##{issue.issue_iid} " \
                   "(attempt #{issue.retry_count + 1})", project: @path)
    end
  end
end
