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
  # `Issue` and `ActivityEvent` are ActiveRecord models (`Issue < ApplicationRecord`,
  # `app/models/issue.rb:12`) — this comment used to say Sequel, which stopped
  # being true when the Rails migration landed, and is exactly the kind of
  # unverified statement Autodev #73 exists for: it would send a reader of
  # `::Issue.where(...)` to `Sequel.expr` instead of ActiveRecord's own query
  # interface.
  class PollDispatcher # rubocop:disable Metrics/ClassLength
    include ExternalState
    include StaleTransitionBound

    ACTIVE_STATUSES = %w[cloning checking_spec implementing committing pushing creating_mr
                         checking_pipeline reviewing fixing_discussions fixing_pipeline].freeze

    # Bounds of the second-chance recovery for a dormant row
    # (`dispatch_dormant_audit`, Autodev #34 then #47/#48): at most 3 extra
    # rounds per ticket, spaced an hour apart, so a transient failure gets
    # another shot once its cause clears while a real code failure just burns
    # the cap.
    DEFAULT_DORMANT_AUDIT_MAX = 3
    DEFAULT_DORMANT_AUDIT_BACKOFF = 3600

    class << self
      # The one definition of "a pass will pick this `error`/`pending` row up
      # on its own, right now" — read by `fetch_retryable` below and, negated
      # and refined to "and never will", by `DormantAudit#error_arm` (Autodev
      # #103). A Ruby predicate rather than a second hand-written SQL string,
      # so the two populations are tested against the same rule instead of
      # against column values that can silently drift apart — which is
      # exactly how a 401 landed in neither: `handle_auth_failure` left
      # `next_retry_at` NULL, `fetch_retryable` requires it non-NULL, and the
      # old `error_arm` required `retry_count > max_retries`, a fact that row
      # never satisfied either.
      def retryable?(issue, max_retries:, now: Time.current)
        issue.retry_count.to_i <= max_retries &&
          !issue.next_retry_at.nil? &&
          issue.next_retry_at <= now
      end
    end

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

    # `usage_ok:` is the Claude-quota verdict AutodevPollJob probed once for the
    # whole cycle (Autodev::UsageGate). It gates only the passes that end in a
    # danger-claude / mr-review call — see #claude_available? (Autodev #46).
    def initialize(config:, project_config:, logger:, usage_ok: true)
      @config = config
      @project_config = project_config
      @logger = logger
      @usage_ok = usage_ok
      @path = project_config['path']
      @token = config['gitlab_token']
      @client = ::GitlabHelpers.build_gitlab_client(config['gitlab_url'], @token)
    end

    def dispatch
      @logger.debug("[poll_dispatcher] #{@path}", project: @path)
      claude_available? ? dispatch_new_issues : log_usage_pause
      return if @config['dry_run']

      dispatch_existing
    rescue StandardError => e
      @logger.error("[poll_dispatcher] #{@path} failed: #{e.class}: #{e.message}",
                    project: @path)
    end

    private

    # An exhausted Claude quota pauses implementation, not observation: only
    # `dispatch_new_issues`, `dispatch_discussions` and the `:retry_stuck`
    # branch of `dispatch_retries` reach danger-claude. Everything else here is
    # GitLab reads, DB transitions and shell hooks, and freezing those was the
    # bug — a ticket closed on GitLab or an MR turning green went unnoticed for
    # the whole outage. `:check_pipeline` keeps running too; PipelineMonitor
    # holds its own gate at the two points where it would call Claude.
    #
    # Nil (a dispatcher built by an older call site or by a unit test) reads as
    # available — the gate must never activate by omission.
    def claude_available? = @usage_ok != false

    def log_usage_pause
      @logger.info('[poll_dispatcher] Claude usage exhausted: implementation paused, ' \
                   'observation passes still running', project: @path)
    end

    def dispatch_existing
      # First, and before anything enqueues: this pass decides whether a row is
      # still ours at all (closed on GitLab, unassigned, or handed back by a
      # label — Autodev #44, #52). It mutates inline, while the two dispatch
      # passes below only enqueue, and `IssueProcessJob#perform` does not
      # re-check the status it was enqueued for. Run after them, a row a human
      # just took back is already in a worker's hands, and a pipeline resolving
      # on the same cycle drives it to `done` — out of `ACTIVE_STATUSES`, so
      # this pass never gets a second look at it — while `apply_label_done`
      # overwrites the label that human set.
      dispatch_unassignment
      dispatch_pipelines
      dispatch_discussions if claude_available?
      dispatch_done_unassigned
      # Before dispatch_retries, so a budget re-armed this cycle is picked up
      # by it immediately rather than waiting a full poll interval.
      dispatch_dormant_audit
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

    # The budget question is asked **first**, and that order is the fix rather
    # than a re-check inside `clarification_received?` (Autodev #75).
    #
    # `skip_existing?` stopped being a predicate when #75 made the clarification
    # branch reachable: it now transitions the row, clears
    # `clarification_requested_at` and posts a note on the ticket. Run before the
    # budget check, it *consumed* the human's answer on a row that was then
    # refused on the next line — the dormant audit can re-arm the row, but the
    # question is no longer on record, so the next look finds nothing to compare a
    # comment against and reads the request as answered and done. The answer is
    # gone, and it is the one thing here that cannot be recomputed.
    #
    # Re-checking the budget inside `clarification_received?` would fix the same
    # symptom and was rejected: it writes `Config.max_retries` at a second call
    # site, and it leaves a method that acts sitting in front of a question about
    # whether autodev may act at all. `exceeded_retries?` asks about the *row*
    # ("may autodev still work this?"), not about its status, so it belongs above
    # every branch that has a side effect. The move is behaviour-neutral for every
    # other status: `skip_existing?` returns true for them and both orders `return`.
    def process_issue(gl_issue)
      existing = ::Issue.where(project_path: @path, issue_iid: gl_issue.iid).first
      return log_budget_spent(existing) if exceeded_retries?(existing)
      return if existing && skip_existing?(existing, gl_issue)
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

    # Narrowed to the waiting state on purpose. A `pending` row over budget has
    # been refused here silently since Autodev #34 and has `dispatch_dormant_audit`
    # to reach a human; logging that population every cycle would be noise. A
    # request in `needs_clarification` has neither — no pass sweeps the state — so
    # a human's answer sitting unread behind a spent budget would otherwise leave
    # no trace anywhere.
    def log_budget_spent(existing)
      return unless existing.status == 'needs_clarification'

      max = ::Config.max_retries(@project_config, @config)
      @logger.info("Issue ##{existing.issue_iid}: waiting for a clarification but the retry budget " \
                   "is spent (#{existing.retry_count}/#{max}) — the question stays on record, " \
                   'nothing is consumed', project: @path)
    end

    def log_dry_run(gl_issue)
      @logger.info("[dry-run] Would process issue ##{gl_issue.iid}: #{gl_issue.title}", project: @path)
    end

    # The second caller of `human_comment_since?`, and the one where the
    # conservative answer really is "no" (Autodev #67). `false` here means the row
    # stays in `needs_clarification`, and `dispatch_new_issues` re-reads the same
    # question from GitLab every cycle — nothing is concluded and nothing acts, so
    # the substitute cannot be mistaken for a verdict the way
    # `open_mr_destination`'s could. Declared at the caller rather than hidden in
    # the helper, so the helper has one behaviour and each boundary owns its own.
    #
    # "Re-reads the same question every cycle" was a claim about a step upstream of
    # this method, and it was false for four months (Autodev #75): `route_by_state`
    # answered `:next` for anything that was not `pending`, so `process_issue` — and
    # therefore this method — was never reached for the state it exists to serve.
    # The rule is now stated once, as `Issue::PROCESSABLE_STATES`, and read by both
    # the router and `IssueProcessJob`.
    def clarification_received?(existing, gl_issue)
      resumer = ClarificationResume.new(client: @client, path: @path, logger: @logger)
      return false unless resumer.answered?(existing)

      resumer.resume!(existing)
      true
    #
    # A 400 is an `InvalidRequestError`, so it is deferred here like an outage and
    # re-asked every cycle. Left as it is by the neutral review of Autodev #95:
    # this reads the ticket's own comments, costs nothing per cycle, and a request
    # parked in `needs_clarification` is waiting on a human anyway.
    rescue ::ApiUnavailableError => e
      @logger.error("Issue ##{gl_issue.iid}: #{e.message} — clarification check deferred", project: @path)
      false
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

    # `error` is deliberately NOT in ACTIVE_STATUSES (Autodev #102). Widening the
    # constant would change the population of every pass that reads it, for a
    # defect that lives in one method: `IssueProcessJob#perform_retry_errored`
    # asks the same question through `Autodev::HandoverStop` before it relaunches.
    def dispatch_unassignment
      ::Issue.where(project_path: @path, status: ACTIVE_STATUSES).find_each do |issue|
        check_external_state(issue)
      end
    end

    # One GitLab read answers all three questions, so detecting a closure or a
    # label handover costs nothing on top of the assignment sweep that already
    # ran here (Autodev #44 for `state`, #52 for `labels` — both used to be
    # fetched and thrown away).
    #
    # The order is the ranking: a ticket closed on GitLab is closed whether or
    # not it is still assigned, and a ticket reassigned to a human is theirs
    # whatever its labels say. Only active rows are swept, so a ticket closed
    # while parked in `pending` or `error` is noticed whenever it next moves,
    # not proactively — `dispatch_dormant_audit` covers that population.
    def check_external_state(issue)
      gl_issue = @client.issue(@path, issue.issue_iid)
      return close_externally(issue) if externally_closed?(gl_issue)
      return stop_unassigned(issue) unless assigned_to_autodev?(gl_issue)

      stop_on_handover(issue, gl_issue)
    # This pass transitions rows in line, so it reaches the refusal the three
    # workers already name (Autodev #97, review of the alpha-52 lot). Without the
    # clause it escaped to `dispatch`'s `rescue StandardError`, which logs and
    # returns — taking the six passes that had not run yet down with it, for the
    # whole project, that cycle. The stop has to be local to the row, as it is in
    # the workers.
    rescue StaleTransitionError => e
      stop_on_stale_transition(e)
    rescue ::Gitlab::Error::ResponseError => e
      @logger.error("Failed to check external state for ##{issue.issue_iid}: #{e.message}",
                    project: @path)
    end

    # The one line `StaleTransitionBound` asks of an including class, spelled here
    # the way `PollRouter` and `DangerClaudeRunner` already spell it.
    def log_error(msg)
      @logger.error(msg, project: @path)
    end

    # `needs_attention: false` is the delivered-vs-given-up discriminator (Autodev
    # #60). This hook is a *delivery* hook — that is the whole argument behind #52
    # routing an interrupted row to `closed` — and an abandoned row is `done`
    # without being delivered: pipeline stagnation, discussion stagnation, an
    # expired pipeline watch, the review-round limit, an exhausted review budget.
    # Two of those already reassigned the ticket to its author and so already
    # slipped past the `still_assigned?` guard into this pass; #60 made the
    # reassignment uniform, which would have let the other three in too. No nominal
    # completion path sets the flag and every give-up path does, so the clause
    # separates the two populations exactly.
    def dispatch_done_unassigned
      pc_cmd = @project_config['post_completion']
      return unless pc_cmd.is_a?(Array) && pc_cmd.any?

      ::Issue.where(project_path: @path, status: 'done', needs_attention: false)
             .where.not(mr_iid: nil).find_each do |issue|
        check_post_completion_needed(issue)
      end
    end

    def check_post_completion_needed(issue)
      return if still_assigned?(issue)

      state = @client.merge_request(@path, issue.mr_iid).state
      return if mr_state_defers_hook?(issue, state)

      IssueProcessJob.perform_later(@path, issue.issue_iid, :post_completion)
      @logger.info("Enqueued post-completion for issue ##{issue.issue_iid}", project: @path)
    rescue ::Gitlab::Error::ResponseError => e
      @logger.error("Failed to check post-completion for ##{issue.issue_iid}: #{e.message}",
                    project: @path)
    end

    def still_assigned?(issue)
      assigned_to_autodev?(@client.issue(@path, issue.issue_iid))
    end

    # The hook is for a delivered ticket whose MR is still open, so two things
    # hold it back and they are not the same thing.
    #
    # `merged` / `closed` are *verdicts*: the MR is over, and there is nothing
    # left for a deploy to deploy from a branch that is gone or already in.
    #
    # A transient state answers nothing (`MrState`, Autodev #72). This used to be
    # one `%w[merged closed].include?` test, so a `locked` MR counted as neither
    # closed nor merged — the opposite of the sort `PipelineMonitor` applies to the
    # same state — and the hook ran *while GitLab was performing the merge*, which
    # for `post_completion` means a deploy. Latent only because no project
    # configures the hook today. The pass re-selects the row every cycle, so
    # waiting costs one deferral and the next cycle reads the outcome.
    def mr_state_defers_hook?(issue, state)
      return true if %w[merged closed].include?(state)
      return false unless MrState.transient?(state)

      @logger.info("Deferring post-completion for issue ##{issue.issue_iid}: MR is #{state}", project: @path)
      true
    end

    # === poll_retries equivalent ===

    def dispatch_retries
      retryable = fetch_retryable
      return if retryable.empty?

      retryable.each { |issue| enqueue_retry(issue) }
    end

    def fetch_retryable
      max_retries = ::Config.max_retries(@project_config, @config)
      now = Time.current
      ::Issue.where(project_path: @path)
             .where(status: %w[error pending])
             .select { |issue| self.class.retryable?(issue, max_retries: max_retries, now: now) }
    end

    # === bounded second look at every row that has stopped moving ===
    #
    # Replaces `dispatch_error_recheck` (#34), whose `error` population is now
    # one of three arms. See Autodev::DormantAudit for the why.
    def dispatch_dormant_audit
      DormantAudit.new(client: @client, path: @path, config: @config,
                       project_config: @project_config, logger: @logger).run
    end

    # Gated by action, not by pass: `:retry_stuck` re-runs IssueProcessor inline
    # (a danger-claude call), while `:retry_errored` only fires transitions and
    # restores GitLab labels. A deferred row keeps its `next_retry_at` stamp, so
    # the next cycle rediscovers it untouched.
    def enqueue_retry(issue)
      action = issue.status == 'pending' ? :retry_stuck : :retry_errored
      return defer_retry(issue) if action == :retry_stuck && !claude_available?

      IssueProcessJob.perform_later(@path, issue.issue_iid, action)
      @logger.info("Enqueued retry (#{action}) for issue ##{issue.issue_iid} " \
                   "(attempt #{issue.retry_count + 1})", project: @path)
    end

    def defer_retry(issue)
      @logger.info("Deferred retry for issue ##{issue.issue_iid}: Claude usage exhausted",
                   project: @path)
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

    # Autodev #110. The row is **reserved** before the job is enqueued, by moving
    # the one column the selection races on. Without it every cycle between the
    # enqueue and the execution re-selected the same row: five enqueues in eighty
    # seconds on 04/09/2026, then five jobs each spending an attempt, `9/5`.
    #
    # Who owns what, and it is not symmetric on purpose:
    #   * this pass owns `infra_recheck_at` — the clock it selects on;
    #   * `InfraRecheck#record_recheck_attempt` owns `infra_recheck_count` — the
    #     budget, spent only by an attempt that actually read a pipeline
    #     (`verdict == :spend`), so a GitLab outage cannot burn the whole watch
    #     window without ever having looked.
    #
    # The UPDATE repeats the whole predicate rather than matching on `id`: that
    # is what makes it a compare-and-set, so two cycles racing on one row cannot
    # both match.
    def dispatch_infra_recheck
      fetch_infra_recheck_candidates.each do |issue|
        next unless reserve_infra_recheck?(issue)

        IssueProcessJob.perform_later(@path, issue.issue_iid, :recheck_infra)
        @logger.info("Enqueued infra recheck for issue ##{issue.issue_iid} " \
                     "(attempt #{(issue.infra_recheck_count || 0) + 1})", project: @path)
      end
    end

    def reserve_infra_recheck?(issue)
      ::Issue.where(id: issue.id, project_path: @path, status: 'done',
                    needs_attention: true, attention_reason: 'stagnation_pipeline')
             .where('infra_recheck_count < ?', Config.infra_recheck_max(@project_config, @config))
             .where("infra_recheck_at IS NULL OR infra_recheck_at <= datetime('now')")
             .update_all(infra_recheck_at: Config.infra_recheck_backoff(@project_config,
                                                                        @config).seconds.from_now)
             .positive?
    end

    def fetch_infra_recheck_candidates
      ::Issue.where(project_path: @path, status: 'done',
                    needs_attention: true, attention_reason: 'stagnation_pipeline')
             .where.not(mr_iid: nil)
             .where('infra_recheck_count < ?', Config.infra_recheck_max(@project_config, @config))
             .where("infra_recheck_at IS NULL OR infra_recheck_at <= datetime('now')")
             .to_a
    end
  end
end
