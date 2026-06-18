# frozen_string_literal: true

module Dashboard
  # Formats and prints error issue details for the --errors command.
  module ErrorDisplay
    module_function

    def print_all(config, pastel)
      issues = fetch_error_issues(config)
      pc_issues = fetch_post_completion_issues(config)
      na_issues = fetch_needs_attention_issues(config)

      print_error_entries(issues, pastel)
      print_extra_entries(pc_issues, na_issues, pastel, issues.any?)

      puts empty_message(config) if (issues + pc_issues + na_issues).empty?
    end

    # -- Private ---------------------------------------------------------------

    def print_error_entries(issues, pastel)
      issues.each_with_index do |row, idx|
        print_entry(row, pastel)
        puts '' if idx < issues.size - 1
      end
    end

    # Post-completion + needs-attention groups, each separated from whatever
    # printed before it.
    def print_extra_entries(pc_issues, na_issues, pastel, had_errors)
      pc_issues.each { |row| print_pc_entry(row, pastel, had_errors) }
      na_issues.each { |row| print_na_entry(row, pastel, had_errors || pc_issues.any?) }
    end

    def fetch_error_issues(config)
      scope = ::Issue.where(status: 'error')
      scope = scope.where(issue_iid: config['errors_iid']) if config['errors_iid']
      scope.order(id: :desc).to_a
    end

    def fetch_post_completion_issues(config)
      scope = ::Issue.where.not(post_completion_error: nil)
      scope = scope.where(issue_iid: config['errors_iid']) if config['errors_iid']
      scope.order(id: :desc).to_a
    end

    # "Gave-up done" issues (review limit / review failures / stagnation):
    # delivered but flagged as needing a manual intervention on GitLab.
    def fetch_needs_attention_issues(config)
      scope = ::Issue.where(needs_attention: true)
      scope = scope.where(issue_iid: config['errors_iid']) if config['errors_iid']
      scope.order(id: :desc).to_a
    end

    def empty_message(config)
      if config['errors_iid']
        "Issue ##{config['errors_iid']} non trouvée ou pas en erreur."
      else
        'Aucune issue en erreur.'
      end
    end

    def print_entry(row, pastel)
      print_header(row, pastel)
      puts ''
      puts pastel.bold('  Erreur:')
      row[:error_message].to_s.lines.each { |l| puts "    #{l}" }
      print_stderr(row, pastel)
    end

    def print_header(row, pastel)
      project_short = row[:project_path].to_s.split('/').last
      icon = pastel.red('■')
      label = pastel.red(row[:status])
      puts pastel.bold("#{icon} Issue ##{row[:issue_iid]}: #{row[:issue_title]} (#{project_short}) [#{label}]")
      print_metadata(row)
    end

    def print_metadata(row)
      puts "  Tentative: #{row[:retry_count]}" if row[:status] == 'error'
      puts "  Branche: #{row[:branch_name]}" if row[:branch_name]
      puts "  MR: !#{row[:mr_iid]} #{row[:mr_url]}" if row[:mr_iid]
    end

    def print_stderr(row, pastel)
      return unless row[:dc_stderr].to_s.strip.length.positive?

      puts ''
      puts pastel.bold('  stderr:')
      row[:dc_stderr].to_s.lines.each { |l| puts "    #{l}" }
    end

    def print_pc_entry(row, pastel, separator)
      project_short = row[:project_path].to_s.split('/').last
      pc_label = pastel.yellow('post_completion')
      puts '' if separator
      print_pc_header(row, pastel, project_short, pc_label)
      print_metadata(row)
      puts ''
      puts pastel.bold('  Post-completion error:')
      row[:post_completion_error].to_s.lines.each { |l| puts "    #{l}" }
    end

    def print_pc_header(row, pastel, project_short, pc_label)
      puts pastel.bold(
        "#{pastel.yellow('▲')} Issue ##{row[:issue_iid]}: " \
        "#{row[:issue_title]} (#{project_short}) [#{pc_label}]"
      )
    end

    def print_na_entry(row, pastel, separator)
      project_short = row[:project_path].to_s.split('/').last
      na_label = pastel.yellow('intervention manuelle')
      puts '' if separator
      puts pastel.bold(
        "#{pastel.yellow('▲')} Issue ##{row[:issue_iid]}: " \
        "#{row[:issue_title]} (#{project_short}) [#{na_label}]"
      )
      print_metadata(row)
      puts "  Raison: #{row[:attention_reason]}"
    end

    private_class_method :fetch_error_issues, :fetch_post_completion_issues,
                         :fetch_needs_attention_issues, :empty_message, :print_error_entries,
                         :print_extra_entries, :print_entry, :print_header, :print_metadata,
                         :print_stderr, :print_pc_entry, :print_pc_header, :print_na_entry
  end
end
