# frozen_string_literal: true

require_relative 'dashboard/table_renderer'
require_relative 'dashboard/error_display'

# Display helpers for the --status, --errors, and --reset CLI commands.
module Dashboard
  STATUS_COLORS = {
    'pending' => :yellow,
    'cloning' => :cyan,
    'checking_spec' => :cyan,
    'implementing' => :cyan,
    'committing' => :cyan,
    'pushing' => :cyan,
    'creating_mr' => :cyan,
    'reviewing' => :cyan,
    'checking_pipeline' => :cyan,
    'fixing_discussions' => :magenta,
    'fixing_pipeline' => :magenta,
    'running_post_completion' => :cyan,
    'answering_question' => :cyan,
    'needs_clarification' => :yellow,
    'done' => :green,
    'error' => :red
  }.freeze

  # Single source of truth is `Issue::ACTIVE_STATES` — the state machine owns
  # its vocabulary. Resolved at call time, not load time: this file is required
  # from a Rails initializer, and touching an autoloaded constant there would
  # pin a stale class across Zeitwerk reloads.
  def self.active_states = Issue::ACTIVE_STATES

  module_function

  def status_label(status)
    case status
    when *Dashboard.active_states then 'En cours'
    when 'pending'              then 'En attente'
    when 'needs_clarification'  then 'En attente de clarification'
    when 'done'                 then 'Terminée'
    when 'error'                then 'Erreur'
    when 'closed'               then 'Clôturée'
    else status
    end
  end

  def show(config)
    pastel = Pastel.new
    issues = fetch_issues(config)

    if issues.empty?
      puts empty_message(config)
    else
      render_dashboard(issues, config, pastel)
    end
  end

  def render_dashboard(issues, config, pastel)
    # WorkerPool used to publish ~/.autodev/workers.json with the in-process
    # thread → issue assignment; with the step-6 supervisor + Solid Queue
    # that state moved to solid_queue_claimed_executions. The CLI dashboard
    # no longer surfaces it — an empty worker_map preserves the column
    # layout while we figure out the cleanest cross-process replacement.
    rows = issues.map { |row| TableRenderer.build_row(row, {}) }
    TableRenderer.print_table(rows, pastel)
    TableRenderer.print_summary(rows, config, pastel)
  end

  def show_errors(config)
    pastel = Pastel.new
    ErrorDisplay.print_all(config, pastel)
  end

  def reset(config, pastel)
    scope = ::Issue.where(status: 'error')
    scope = scope.where(issue_iid: config['reset_iid']) if config['reset_iid']

    if scope.none?
      puts reset_empty_message(config)
      return
    end

    perform_reset(scope, config, pastel)
  end

  # -- Private helpers ---------------------------------------------------------

  def fetch_issues(config)
    scope = ::Issue.order(id: :desc)
    scope = scope.where.not(status: %w[done closed]) unless config['status_all']
    scope.to_a
  end

  def empty_message(config)
    if config['status_all']
      'Aucune issue suivie.'
    else
      'Aucune issue active. Utilisez --all pour inclure les issues terminées.'
    end
  end

  def reset_empty_message(config)
    if config['reset_iid']
      "Issue ##{config['reset_iid']} non trouvée ou pas en erreur."
    else
      'Aucune issue en erreur.'
    end
  end

  def perform_reset(scope, config, pastel)
    count = scope.count
    # The MR split and the `next_retry_at` stamp (task #26) now live in
    # Issue.reset_for_retry! — this used to be their only correct copy, while
    # the dashboard button and recover_errored! each got a piece wrong (#34).
    # `reset_budget:` because an operator asking for a reset wants a clean slate.
    Issue.reset_for_retry!(scope, reset_budget: true)
    label = config['reset_iid'] ? "Issue ##{config['reset_iid']}" : "#{count} issue(s)"
    puts pastel.green("✓ #{label} relancée(s).")
  end

  private_class_method :fetch_issues, :empty_message, :reset_empty_message, :perform_reset
end
