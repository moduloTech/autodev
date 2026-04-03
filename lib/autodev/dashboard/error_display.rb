# frozen_string_literal: true

module Dashboard
  # Formats and prints error/blocked issue details for the --errors command.
  module ErrorDisplay
    module_function

    def print_all(config, pastel)
      issues = fetch_error_issues(config)
      issues.each_with_index do |row, idx|
        print_entry(row, pastel)
        puts '' if idx < issues.size - 1
      end

      pc_issues = fetch_post_completion_issues(config)
      pc_issues.each { |row| print_pc_entry(row, pastel, issues.any?) }

      puts empty_message(config) if issues.empty? && pc_issues.empty?
    end

    # -- Private ---------------------------------------------------------------

    def fetch_error_issues(config)
      dataset = Database.db[:issues].where(status: %w[error blocked])
      dataset = dataset.where(issue_iid: config['errors_iid']) if config['errors_iid']
      dataset.order(Sequel.desc(:id)).all
    end

    def fetch_post_completion_issues(config)
      dataset = Database.db[:issues].exclude(post_completion_error: nil)
      dataset = dataset.where(issue_iid: config['errors_iid']) if config['errors_iid']
      dataset.order(Sequel.desc(:id)).all
    end

    def empty_message(config)
      if config['errors_iid']
        "Issue ##{config['errors_iid']} non trouvée ou pas en erreur/bloquée."
      else
        'Aucune issue en erreur ou bloquée.'
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
      color = row[:status] == 'blocked' ? :yellow : :red
      icon = pastel.send(color, '■')
      label = pastel.send(color, row[:status])
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

    private_class_method :fetch_error_issues, :fetch_post_completion_issues, :empty_message,
                         :print_entry, :print_header, :print_metadata, :print_stderr,
                         :print_pc_entry, :print_pc_header
  end
end
