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

  ACTIVE_STATES = %w[
    cloning checking_spec implementing committing pushing
    creating_mr reviewing checking_pipeline
    fixing_discussions fixing_pipeline running_post_completion
  ].freeze

  module_function

  def status_label(status)
    case status
    when *ACTIVE_STATES then 'En cours'
    when 'pending'              then 'En attente'
    when 'needs_clarification'  then 'En attente de clarification'
    when 'done'                 then 'Terminée'
    when 'error'                then 'Erreur'
    else status
    end
  end

  def show(config)
    pastel = Pastel.new
    Database.connect(config['database_url'])
    Database.build_model!
    issues = fetch_issues(config)

    if issues.empty?
      puts empty_message(config)
    else
      render_dashboard(issues, config, pastel)
    end
  end

  def render_dashboard(issues, config, pastel)
    worker_map = WorkerPool.read_assignments.invert
    rows = issues.map { |row| TableRenderer.build_row(row, worker_map) }
    TableRenderer.print_table(rows, pastel)
    TableRenderer.print_summary(rows, config, pastel)
  end

  def show_errors(config)
    pastel = Pastel.new
    Database.connect(config['database_url'])
    Database.build_model!
    ErrorDisplay.print_all(config, pastel)
  end

  def reset(config, pastel)
    Database.connect(config['database_url'])
    Database.build_model!
    dataset = Database.db[:issues].where(status: 'error')
    dataset = dataset.where(issue_iid: config['reset_iid']) if config['reset_iid']

    if dataset.none?
      puts reset_empty_message(config)
      return
    end

    perform_reset(dataset, config, pastel)
  end

  # -- Private helpers ---------------------------------------------------------

  def fetch_issues(config)
    dataset = Database.db[:issues].order(Sequel.desc(:id))
    dataset = dataset.exclude(status: 'done') unless config['status_all']
    dataset.all
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

  def perform_reset(dataset, config, pastel)
    count = dataset.count
    dataset.update(status: 'pending', retry_count: 0, error_message: nil, next_retry_at: nil, started_at: nil)
    label = config['reset_iid'] ? "Issue ##{config['reset_iid']}" : "#{count} issue(s)"
    puts pastel.green("✓ #{label} remise(s) en pending.")
  end

  private_class_method :fetch_issues, :empty_message, :reset_empty_message, :perform_reset
end
