# frozen_string_literal: true

module Dashboard
  # Builds and prints the issue status table for the --status command.
  module TableRenderer
    module_function

    def build_row(row, worker_map)
      project_short = row[:project_path].to_s.split('/').last
      title = row[:issue_title].to_s
      title = "#{title[0, 37]}…" if title.length > 38
      status = row[:status]
      comment = build_comment(row, status, worker_map)

      { iid: "##{row[:issue_iid]}", title: "#{title} (#{project_short})", status: status, comment: comment }
    end

    def print_table(rows, pastel)
      widths = compute_widths(rows)
      sep = separator(widths)
      puts sep
      puts pastel.bold(header(widths))
      puts sep
      rows.each { |row| puts format_row(row, widths, pastel) }
      puts sep
    end

    def print_summary(rows, config, pastel)
      counts = count_by_status(rows)
      summary = format_counts(counts, rows.size, pastel)
      append_hidden_count(summary, config, pastel)
      puts summary
    end

    # -- Private ---------------------------------------------------------------

    def build_comment(row, status, worker_map)
      comment = Dashboard.status_label(status).dup
      comment << " (#{status})" if ACTIVE_STATES.include?(status)
      worker = worker_map[row[:issue_iid]]
      comment << " [worker-#{worker}]" if worker
      comment << " — MR !#{row[:mr_iid]}" if row[:mr_url]
      append_error_excerpt(comment, row) if status == 'error'
      append_clarification(comment, row) if status == 'needs_clarification'
      comment
    end

    def append_error_excerpt(comment, row)
      return unless row[:error_message]

      err = row[:error_message].to_s.lines.first.to_s.strip
      err = "#{err[0, 40]}…" if err.length > 41
      comment << " — #{err}"
    end

    def append_clarification(comment, row)
      comment << " depuis #{row[:clarification_requested_at]}" if row[:clarification_requested_at]
    end

    def compute_widths(rows)
      { iid: 5, title: 5, status: 8, comment: 12 }.tap do |widths|
        widths.each_key { |k| widths[k] = [rows.map { |r| r[k].length }.max, widths[k]].max }
      end
    end

    def separator(widths)
      "+-#{'-' * widths[:iid]}-+-#{'-' * widths[:title]}-+-#{'-' * widths[:status]}-+-#{'-' * widths[:comment]}-+"
    end

    def header(widths)
      "| #{'#'.ljust(widths[:iid])} | #{'Issue'.ljust(widths[:title])} " \
        "| #{'État'.ljust(widths[:status])} | #{'Commentaire'.ljust(widths[:comment])} |"
    end

    def format_row(row, widths, pastel)
      color = STATUS_COLORS[row[:status]] || :white
      colored_status = pastel.send(color, row[:status].ljust(widths[:status]))
      "| #{row[:iid].ljust(widths[:iid])} | #{row[:title].ljust(widths[:title])} " \
        "| #{colored_status} | #{row[:comment].ljust(widths[:comment])} |"
    end

    def count_by_status(rows)
      {
        active: rows.count { |r| ACTIVE_STATES.include?(r[:status]) || r[:status] == 'pending' },
        done: rows.count { |r| r[:status] == 'over' },
        blocked: rows.count { |r| %w[blocked error needs_clarification].include?(r[:status]) }
      }
    end

    def format_counts(counts, total, pastel)
      "#{pastel.bold(total.to_s)} issues " \
        "— #{pastel.cyan("#{counts[:active]} actives")}, " \
        "#{pastel.green("#{counts[:done]} terminées")}, " \
        "#{pastel.yellow("#{counts[:blocked]} bloquées")}"
    end

    def append_hidden_count(summary, config, pastel)
      return if config['status_all']

      hidden = Database.db[:issues].where(status: 'over').count
      summary << " #{pastel.dim("(#{hidden} terminées masquées, --all pour tout voir)")}" if hidden.positive?
    end

    private_class_method :build_comment, :append_error_excerpt, :append_clarification,
                         :compute_widths, :separator, :header, :format_row,
                         :count_by_status, :format_counts, :append_hidden_count
  end
end
