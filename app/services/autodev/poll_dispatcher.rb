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

    # Bounds of the second-chance recovery for a spent retry budget
    # (`dispatch_error_recheck`, Autodev #34): at most 3 extra rounds per
    # ticket, spaced an hour apart, so a transient failure gets another shot
    # once its cause clears while a real code failure just burns the cap.
    DEFAULT_ERROR_RECHECK_MAX = 3
    DEFAULT_ERROR_RECHECK_BACKOFF = 3600

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
      # Before dispatch_retries, so a budget re-armed this cycle is picked up
      # by it immediately rather than waiting a full poll interval.
      dispatch_error_recheck
      dispatch_retries
      dispatch_infra_recheck
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

      # `>`, not `>=`: the budget counts retries, so a row sitting exactly at
      # it still has one owed (see Config.max_retries — Autodev #34).
      existing.retry_count > ::Config.max_retries(@project_config, @config)
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
      author = gl_issue.author
      ::Issue.create(project_path: @path, issue_iid: gl_issue.iid,
                     issue_title: gl_issue.title, status: 'pending',
                     issue_author_id: author&.id,
                     issue_author_name: author&.name, locale: locale.to_s)
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
      max_retries = ::Config.max_retries(@project_config, @config)
      ::Issue.where(project_path: @path)
             .where(status: %w[error pending])
             .where('retry_count <= ?', max_retries)
             .where("next_retry_at IS NOT NULL AND next_retry_at <= datetime('now')")
             .to_a
    end

    # === bounded second chance for a spent retry budget ===
    #
    # Exhausting `max_retries` is right for a genuine code failure but wrong for
    # a transient one (network blip, GitLab/registry outage, the #33 `git push`
    # stale-info case): the row sat in `error` forever, needing a manual UPDATE.
    #
    # This pass does NOT reimplement the retry mechanics. It re-arms the spent
    # budget — `retry_count` back to 0 plus a due `next_retry_at` — and lets
    # `dispatch_retries` (which runs right after) take it through the usual
    # `:retry_errored` / `:retry_stuck` path, labels and activity log included.
    #
    # It deliberately does not classify the error. `JobClassifier` reads GitLab
    # CI `failure_reason` values, not Ruby exceptions, so classifying here would
    # mean a new brittle heuristic over `error_message`. A real code failure
    # instead burns the cap — a few extra rounds spread over hours — and then
    # rests terminal, which is the bound we actually need.
    def dispatch_error_recheck
      fetch_error_recheck_candidates.each { |issue| recheck_errored(issue) }
    end

    def fetch_error_recheck_candidates
      ::Issue.where(project_path: @path, status: 'error')
             .where('retry_count > ?', ::Config.max_retries(@project_config, @config))
             .where('error_recheck_count < ?', error_recheck_max)
             .where("error_recheck_at IS NULL OR error_recheck_at <= datetime('now')")
             .to_a
    end

    # Every candidate costs one bounded attempt whether or not it gets re-armed,
    # so a closed-and-forgotten ticket can't make us call GitLab on every poll
    # forever.
    def recheck_errored(issue)
      attempt = (issue.error_recheck_count || 0) + 1
      stamps = { error_recheck_count: attempt,
                 error_recheck_at: error_recheck_backoff.seconds.from_now }
      stamps.merge!(retry_count: 0, next_retry_at: Time.current) if worth_rearming?(issue)
      issue.update(**stamps)
      log_error_recheck(issue, attempt, stamps.key?(:retry_count))
    rescue ::Gitlab::Error::ResponseError => e
      @logger.error("Failed to recheck errored ##{issue.issue_iid}: #{e.message}", project: @path)
    end

    # One GitLab read answers both questions — a ticket that was closed or
    # handed to a human is not ours to retry.
    def worth_rearming?(issue)
      gl_issue = @client.issue(@path, issue.issue_iid)
      return false unless gl_issue.state == 'opened'

      (gl_issue.assignees || []).any? { |a| a.id == ::GitlabHelpers.current_user_id(@client) }
    end

    def log_error_recheck(issue, attempt, rearmed)
      verb = rearmed ? 'rearmed retry budget' : 'declined (closed or unassigned)'
      @logger.info("Error recheck #{attempt}/#{error_recheck_max} for issue " \
                   "##{issue.issue_iid}: #{verb}", project: @path)
    end

    def error_recheck_max
      (@project_config['error_recheck_max'] || @config['error_recheck_max'] ||
        DEFAULT_ERROR_RECHECK_MAX).to_i
    end

    def error_recheck_backoff
      (@project_config['error_recheck_backoff'] || @config['error_recheck_backoff'] ||
        DEFAULT_ERROR_RECHECK_BACKOFF).to_i
    end

    def enqueue_retry(issue)
      action = issue.status == 'pending' ? :retry_stuck : :retry_errored
      IssueProcessJob.perform_later(@path, issue.issue_iid, action)
      @logger.info("Enqueued retry (#{action}) for issue ##{issue.issue_iid} " \
                   "(attempt #{issue.retry_count + 1})", project: @path)
    end

    # === infra-recovery recheck ===
    #
    # Tickets that stagnated on an INFRA/deploy failure sit in `done` +
    # `needs_attention` + `attention_reason: 'stagnation_pipeline'` and were
    # never re-attempted once CI recovered. Re-enqueue the still-open,
    # under-cap, backoff-elapsed ones so `:recheck_infra` re-classifies their
    # current pipeline (infra-vs-code at recheck time) and re-enters on
    # recovery. Only `stagnation_pipeline` is targeted — never
    # `stagnation_discussions`, never a code-origin give-up.

    def dispatch_infra_recheck
      fetch_infra_recheck_candidates.each do |issue|
        IssueProcessJob.perform_later(@path, issue.issue_iid, :recheck_infra)
        @logger.info("Enqueued infra recheck for issue ##{issue.issue_iid} " \
                     "(attempt #{(issue.infra_recheck_count || 0) + 1})", project: @path)
      end
    end

    def fetch_infra_recheck_candidates
      ::Issue.where(project_path: @path, status: 'done',
                    needs_attention: true, attention_reason: 'stagnation_pipeline')
             .where.not(mr_iid: nil)
             .where('infra_recheck_count < ?', infra_recheck_max)
             .where("infra_recheck_at IS NULL OR infra_recheck_at <= datetime('now')")
             .to_a
    end

    def infra_recheck_max
      (@project_config['infra_recheck_max'] || @config['infra_recheck_max'] ||
        ::PipelineMonitor::DEFAULT_INFRA_RECHECK_MAX).to_i
    end
  end
end
