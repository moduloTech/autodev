# frozen_string_literal: true

require_relative 'poll_router/resume_handler'

# Routes GitLab issues to the appropriate processor based on their labels and DB state.
# Extracts the label-driven routing logic from the polling loop in bin/autodev.
class PollRouter
  include LabelManager
  include ResumeHandler

  def initialize(config:, project_config:, logger:, token:, pool:)
    @config         = config
    @project_config = project_config
    @logger         = logger
    @token          = token
    @pool           = pool
    init_project_settings(project_config)
  end

  # Route a single GitLab issue. Returns :next (skip to next issue) or :process (continue to processing).
  #
  # The boundary of one issue's routing (Autodev #67). The reentry decision reads
  # the MR state and, for an open MR, the issue's comment history; a read GitLab
  # could not answer must decide nothing, and the row is left exactly as it was
  # for `dispatch_new_issues` to re-ask next cycle. The boundary is per *issue*
  # rather than per pass: raised any higher it would land in `PollDispatcher#dispatch`'s
  # own `rescue StandardError`, and one unreadable MR would take the whole
  # project's cycle down with it — the pipeline checks, the discussion fixes and
  # the retries included.
  def route(gl_issue, client)
    return :process unless @use_labels

    @client = @route_client = client
    existing = Issue.where(project_path: @project_path, issue_iid: gl_issue.iid).first
    route_by_state(gl_issue, existing)
  rescue ApiUnavailableError => e
    log_error "Issue ##{gl_issue.iid}: #{e.message} — routing deferred to the next cycle"
    :next
  end

  # Public entry for PollDispatcher's infra-recheck pass. An infra-origin
  # stagnation whose CI has recovered re-enters the pipeline-check flow using
  # the exact same reset a human re-adding labels_todo triggers
  # (ResumeHandler#reenter_via_pipeline_check): back to `checking_pipeline`,
  # `needs_attention` cleared, review/fix counters reset, label doing re-applied.
  def resume_recovered_infra(issue, client)
    @client = @route_client = client
    reenter_via_pipeline_check(issue)
  end

  private

  def init_project_settings(project_config)
    @project_path = project_config['path']
    @use_labels   = Config.label_workflow?(project_config)
  end

  # `:process` does not mean "start implementing" — it means "hand this row to
  # `PollDispatcher#process_issue`", which is where the decision actually lives:
  # `skip_existing?` re-reads the status and only a `pending` row is enqueued.
  #
  # That is why the last line asks `Issue::PROCESSABLE_STATES` rather than
  # `== 'pending'` (Autodev #75). A row in `needs_clarification` has one question
  # left to ask — did the human answer? — and `process_issue` is the only code
  # that asks it. Answering `:next` here dropped the row one step before the
  # question, so the answer was never read: 12 production tickets parked on
  # PowerPanne, the oldest since 15/05/2026, three of them still carrying a todo
  # label and therefore rediscovered by `dispatch_new_issues` every five minutes
  # with a human answer already on the thread.
  def route_by_state(gl_issue, existing)
    return :process unless existing

    if reenterable?(existing)
      handle_reenter(gl_issue, existing)
      return :next
    end

    Issue::PROCESSABLE_STATES.include?(existing.status) ? :process : :next
  end

  # `done` always reenters. `closed` only does when somebody applied a todo label
  # *after* the row was closed (Autodev #52).
  #
  # That threshold is what makes reentry from a terminal state safe. A stop
  # decided by a human — unassignment, or a workflow-label handover — now ends in
  # `closed`, and the documented loop ("repose the todo label, reassign autodev")
  # has to keep working or the stop is a trap. But `closed` is also what the
  # dashboard's close button writes, and there the todo label was already on the
  # ticket before the click: comparing against `finished_at` tells the two apart,
  # so the button keeps working as an off-switch and only a fresh request wins.
  #
  # Costs one `issue_label_events` call per cycle, for every row that is
  # `closed` in the DB while its GitLab issue is still open, still assigned to
  # autodev and still carrying a todo label — the population
  # `dispatch_new_issues` hands to `route`.
  #
  # That cost is recurring, not transient (Autodev #60 corrected this comment,
  # which used to claim the population "empties itself"). It does for a row that
  # reenters, because reentry leaves `closed`. It does **not** for the case the
  # gate exists to reject: a ticket closed from the dashboard with the todo label
  # left in place. There the label event predates `finished_at` for good, so
  # `todo_reapplied_after?` answers false on every cycle, nothing about the row
  # changes, and it pays one API call every poll interval indefinitely. Removing
  # the label on GitLab is the only thing that ends it.
  #
  # Measured on the 12/08/2026 production copy: 60 `closed` rows, **none** of
  # them still open + todo-labelled on GitLab, so the recurring cost is zero
  # calls today. That is why the cost is documented rather than bounded — a cache
  # or an `issue_label_events`-free short-circuit would be paying complexity for
  # an empty set. Re-measure before adding one.
  def reenterable?(existing)
    return true if existing.status == 'done'
    return false unless existing.status == 'closed'

    Autodev::LabelHandover
      .new(client: @route_client, path: @project_path,
           project_config: @project_config, logger: @logger)
      .todo_reapplied_after?(existing.issue_iid, existing.finished_at)
  end

  def enqueue_issue_processing(gl_issue, existing)
    processor = IssueProcessor.new(client: build_worker_client, config: @config,
                                   project_config: @project_config, logger: @logger, token: @token)
    @pool.enqueue?(issue_iid: existing.issue_iid) { processor.process(existing) }
    @logger.info("Enqueued resumed issue ##{gl_issue.iid}: #{gl_issue.title}", project: @project_path)
  end

  def build_worker_client
    GitlabHelpers.build_gitlab_client(@config['gitlab_url'], @token)
  end

  def log_activity(issue, key)
    ActivityLogger.post(ActivityLogger::Ctx.new(@route_client, @project_path, @logger), issue, key)
  end

  def log(msg)
    @logger.info(msg, project: @project_path)
  end

  def log_error(msg)
    @logger.error(msg, project: @project_path)
  end
end
