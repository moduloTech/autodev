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
#   :recheck_infra     → re-classify an infra-stagnated done row's pipeline;
#                        re-enter checking_pipeline if CI has recovered
#
# Concurrency: at most one execution per (project_path, issue_iid) at a
# time. The N=3 global cap comes from queue.yml's worker `threads` setting,
# not from per-key concurrency.
# ClassLength: the seven `perform_*` bodies and the two tables that describe
# them (ACTIONS + DISPATCHED_FROM) are one dispatch table; splitting it would
# put the declaration of an action away from its precondition.
class IssueProcessJob < ApplicationJob # rubocop:disable Metrics/ClassLength
  queue_as :default

  limits_concurrency to: 1,
                     key: ->(project_path, issue_iid, *_) { "issue-#{project_path}-#{issue_iid}" },
                     duration: 1.hour

  ACTIONS = %i[process check_pipeline fix_discussions post_completion
               retry_errored retry_stuck recheck_infra].freeze

  # Actions that end in a danger-claude call. `Autodev::PollDispatcher` already
  # skips the passes that produce them while the Claude quota is out, but a job
  # enqueued just before the outage can still be sitting in the queue — hence
  # this second, defensive gate (Autodev #46). Each of the three leaves its row
  # in a state the next cycle rediscovers (`pending` / `fixing_discussions` /
  # `pending` + `next_retry_at`), so returning early loses no work.
  CLAUDE_CONSUMING_ACTIONS = %i[process fix_discussions retry_stuck].freeze

  # The row state each action was dispatched from, mirroring the `where` of the
  # `Autodev::PollDispatcher` pass that enqueues it (Autodev #61).
  #
  # The queue is not a snapshot. `dispatch_pipelines` enqueues the whole
  # `checking_pipeline` population every cycle, so any job that outlives the
  # poll interval leaves duplicates behind it — and once Autodev #51 turned a
  # `manual` pipeline from a millisecond no-op into a full mr-review run, that
  # became the normal case rather than the exception.
  #
  # The state machine does not stop those duplicates. `whiny_transitions:
  # false` makes an impossible transition a silent no-op rather than a raise,
  # and the callers treat the event as a command that always succeeds:
  # `green_first_review` calls `launch_review` after a `pipeline_green!` that
  # did nothing, and `give_up_reviewing` re-applies the end label, reassigns the
  # author and posts a GitLab comment after a `review_giveup!` that did
  # nothing. On 11/08/2026 that put 486 comments on 28 powerpanne tickets in
  # two hours — issue #15839 alone took 26 identical ones, one every 105
  # seconds, every one of them after its last real transition.
  #
  # Guarding here rather than at each call site is deliberate: the precondition
  # is a property of the *action*, one declaration covers all seven, and the
  # row has just been read anyway. It is not a substitute for a per-issue lock
  # (`limits_concurrency` is that) — it answers the different question of
  # whether the work this job was queued for still needs doing.
  DISPATCHED_FROM = {
    process: ::Issue::PROCESSABLE_STATES,
    check_pipeline: %w[checking_pipeline].freeze,
    fix_discussions: %w[fixing_discussions].freeze,
    post_completion: %w[done].freeze,
    retry_errored: %w[error].freeze,
    retry_stuck: %w[pending].freeze,
    recheck_infra: %w[done].freeze
  }.freeze

  def perform(project_path, issue_iid, action)
    action = action.to_sym
    raise ArgumentError, "unknown action #{action.inspect}" unless ACTIONS.include?(action)
    return log_usage_skip(project_path, issue_iid, action) if usage_blocked?(action)

    config = ::Config.load
    project_config = lookup_project_config(config, project_path)
    return unless project_config

    issue = ::Issue.where(project_path: project_path, issue_iid: issue_iid).first
    return unless issue
    return log_stale_skip(project_path, issue, action) unless dispatchable?(issue, action)

    public_send("perform_#{action}", issue, config, project_config)
  end

  private

  def dispatchable?(issue, action)
    DISPATCHED_FROM.fetch(action).include?(issue.status.to_s)
  end

  # INFO, not WARN: on a healthy instance this fires whenever a row resolves
  # faster than the cycle that queued it again, which is normal. It becoming
  # *frequent* is the signal — that the queue is running behind the poller.
  def log_stale_skip(project_path, issue, action)
    logger.info("[issue_process] skipping #{action} for #{project_path}##{issue.issue_iid}: " \
                "row is #{issue.status}, expected #{DISPATCHED_FROM.fetch(action).join(' or ')}")
  end

  def usage_blocked?(action)
    CLAUDE_CONSUMING_ACTIONS.include?(action) && !::Autodev::UsageGate.available?
  end

  def log_usage_skip(project_path, issue_iid, action)
    logger.info("[issue_process] skipping #{action} for #{project_path}##{issue_iid}: " \
                'Claude usage exhausted')
  end

  # Phase 2 of task #9: the per-project config comes from the DB. Every
  # per-project key is now columnized, so a `projects` row is the complete,
  # authoritative config (the importer mirrors the YAML into columns, so this
  # is behaviour-neutral on an imported DB). With no row yet (e.g. a project
  # added to the YAML before the next `autodev:migrate_projects_from_yaml` run)
  # we fall back to the YAML entry — a soft transition that never regresses a
  # project.
  def lookup_project_config(config, project_path)
    db_config = ::Project.find_by(gitlab_path: project_path)&.to_project_config
    return db_config if db_config

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
      # Legacy workflow classes (IssueProcessor, MrFixer, PipelineMonitor,
      # ActivityLogger) call `logger.info(msg, project: …)` — kwargs that
      # AppLogger accepted but Rails' Logger doesn't. JobLogger discards them.
      logger: ::Autodev::JobLogger.new(logger),
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

  # Re-classify the infra-stagnated ticket's CURRENT head pipeline. Only when
  # CI has recovered does PipelineMonitor return true; we then re-enter the
  # pipeline-check flow via the exact same reset ResumeHandler uses when a human
  # re-adds labels_todo (needs_attention cleared, back to checking_pipeline).
  def perform_recheck_infra(issue, config, project_config)
    monitor = ::PipelineMonitor.new(**worker_kwargs(config, project_config))
    return unless monitor.recheck_infra_recovery(issue)

    ::PollRouter.new(config: config, project_config: project_config,
                     logger: ::Autodev::JobLogger.new(logger),
                     token: config['gitlab_token'], pool: nil)
                .resume_recovered_infra(issue, build_client(config))
  end

  def perform_post_completion(issue, config, project_config)
    monitor = ::PipelineMonitor.new(**worker_kwargs(config, project_config))
    issue.start_post_completion!
    ctx = ::ActivityLogger::Ctx.new(build_client(config), project_config['path'],
                                    ::Autodev::JobLogger.new(logger))
    ::ActivityLogger.post(ctx, issue, :post_completion)
    monitor.run_post_completion(issue, project_config['post_completion'])
    issue.post_completion_done!
  end

  # Autodev #111. Entering `error` writes the retry decision (`mark_failed`
  # stamps `next_retry_at`); leaving it erases that decision. Both recovery
  # paths do it — they used not to, for no reason written anywhere, and
  # `PollDispatcher.retryable?` reads the stamp, `retry_count` and nothing else,
  # so a residue is a scheduled return nobody decided on. It survived only
  # because `fetch_retryable` filters on status; that filter is a second line,
  # not the rule.
  # `handed_over?` returns early — closing the row and posting the handover
  # comment itself, not merely answering a question — on a yes.
  def perform_retry_errored(issue, config, project_config)
    return if handed_over?(issue, config, project_config)

    has_mr = !issue.mr_iid.nil?
    has_mr ? issue.retry_pipeline! : issue.retry_processing!
    issue.update(error_message: nil, started_at: nil, next_retry_at: nil)
    restore_working_label(issue, config, project_config)
    log_retry_activity(issue, config, project_config)
  end

  def perform_retry_stuck(issue, config, project_config)
    issue.update(next_retry_at: nil)
    log_retry_activity(issue, config, project_config)
    ::IssueProcessor.new(**worker_kwargs(config, project_config)).process(issue)
  end

  private

  # Autodev #102. `error` is outside `dispatch_unassignment`'s ACTIVE_STATUSES
  # sweep, so this is the only place the question gets asked before autodev
  # writes on the ticket again. A read that could not answer declines the retry
  # for this cycle and leaves the row exactly as it was — the Autodev #67 rule,
  # and the choice Autodev #93 made for `UntouchedSinceGiveup`: an unreadable
  # ticket is never permission to take it.
  #
  # Costs one GitLab read per errored retry — not per poll cycle. `manage_labels`
  # does read the issue, but inside `apply_label_doing`, i.e. after the
  # transition, which is too late to be the one this needs.
  #
  # The read is wrapped in `GitlabHelpers.answer` — branch review: a raw
  # `client.issue` left the transport family (`Errno::ECONNREFUSED` among them,
  # ~9% of GitLab reads from bobette per Autodev #96) to escape as a job
  # failure rather than the clean decline below, even though the rescue clause
  # already covered `ApiUnavailableError`. Wrapping makes the two agree.
  def handed_over?(issue, config, project_config)
    client = build_client(config)
    gl_issue = read_gitlab_issue(client, project_config, issue)
    stopper = ::Autodev::HandoverStop.new(client: client, path: project_config['path'],
                                          project_config: project_config,
                                          logger: ::Autodev::JobLogger.new(logger))
    !stopper.stop_on_handover(issue, gl_issue).nil?
  rescue ::ApiUnavailableError => e
    logger.warn("Declining the retry of ##{issue.issue_iid}: could not read the ticket " \
                "(#{e.class}: #{e.message})")
    true
  end

  def read_gitlab_issue(client, project_config, issue)
    ::GitlabHelpers.answer(:issue) { client.issue(project_config['path'], issue.issue_iid) }
  end

  # A retry resumes the work; it does not deliver it (Autodev #100).
  #
  # This used to fork on whether the request carried a merge request and pose
  # `label_done` when it did — but both destinations are working states,
  # `retry_pipeline!` → `checking_pipeline` and `retry_processing!` → `pending`,
  # so the fork announced the work as finished while autodev carried on. On
  # powerpanne that label is `Development::Awaiting Feature Review`, the review
  # column: request 15205 sat in it for ten hours on 02/09/2026 while rounds 5 to
  # 18 of discussion fixing ran underneath.
  #
  # The fork was right when it was written. "Label-driven workflow with resume
  # from over" declared five labels, `label_mr` ("set after MR creation, enables
  # discussion monitoring") among them, and this restored exactly the one
  # matching the destination. `label_mr` was later **renamed** `label_done`,
  # taking over the meaning of a different label, and the call site kept its
  # method name. There is no question left for the fork to answer, so it is gone
  # rather than corrected.
  def restore_working_label(issue, config, project_config)
    return unless ::Config.label_workflow?(project_config)

    ::MrFixer.new(**worker_kwargs(config, project_config)).apply_label_doing(issue.issue_iid)
  rescue StandardError => e
    logger.error("Failed to restore the working label on ##{issue.issue_iid}: #{e.class}: #{e.message}")
  end

  def log_retry_activity(issue, config, project_config)
    max = ::Config.max_retries(project_config, config)
    ctx = ::ActivityLogger::Ctx.new(build_client(config), project_config['path'],
                                    ::Autodev::JobLogger.new(logger))
    ::ActivityLogger.post(ctx, issue, :retry, attempt: issue.retry_count + 1, max: max)
  end
end
