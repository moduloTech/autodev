# frozen_string_literal: true

class MrFixer
  # Formats MR discussion notes and extracts diff hunks for review context.
  # Expects the including class to provide `run_cmd_status` (via DangerClaudeRunner).
  module DiscussionFormatter
    private

    def format_discussion(discussion, work_dir: nil, target_branch: nil)
      lines = []
      diff_shown = false

      discussion[:notes].each do |note|
        diff_shown = format_note(lines, note, work_dir: work_dir, target_branch: target_branch, diff_shown: diff_shown)
      end
      lines.join("\n")
    end

    def format_note(lines, note, work_dir:, target_branch:, diff_shown:)
      author = note.author&.name || 'Unknown'
      lines << "### #{author} (#{note.created_at})"

      diff_shown = append_position_info(lines, note,
                                        work_dir: work_dir,
                                        target_branch: target_branch,
                                        diff_shown: diff_shown)

      lines << ''
      lines << note.body.to_s
      lines << ''
      diff_shown
    end

    def append_position_info(lines, note, work_dir:, target_branch:, diff_shown:)
      return diff_shown unless note.respond_to?(:position) && note.position

      pos = note.position
      file_path = pos_field(pos, :new_path)
      return diff_shown unless file_path

      new_line = pos_field(pos, :new_line)
      old_line = pos_field(pos, :old_line)
      lines << format_location(file_path, new_line, old_line)
      return diff_shown if diff_shown

      append_diff(lines, work_dir, target_branch, file_path, new_line || old_line) || diff_shown
    end

    def format_location(file_path, new_line, old_line)
      location = "Fichier: `#{file_path}`"
      location << " (ligne #{new_line})" if new_line
      location << " (ancienne ligne #{old_line})" if old_line && !new_line
      location
    end

    def append_diff(lines, work_dir, target_branch, file_path, line)
      return unless work_dir && target_branch

      hunk = extract_diff_hunk(work_dir, target_branch, file_path, line)
      return unless hunk

      lines.push('', '#### Diff', '```diff', hunk, '```')
      true
    end

    def extract_diff_hunk(work_dir, target_branch, file_path, target_line)
      diff_output = fetch_file_diff(work_dir, target_branch, file_path)
      return nil unless diff_output

      return diff_output unless target_line

      find_hunk_for_line(diff_output, target_line.to_i) || diff_output
    rescue StandardError
      nil
    end

    def fetch_file_diff(work_dir, target_branch, file_path)
      output, _err, ok = run_cmd_status(
        ['git', 'diff', "origin/#{target_branch}..HEAD", '--', file_path],
        chdir: work_dir
      )
      ok && output && !output.strip.empty? ? output : nil
    end

    def find_hunk_for_line(diff_output, target_line)
      diff_output.split(/(?=^@@)/).each do |hunk|
        next unless hunk.start_with?('@@')

        match = hunk.match(/^@@ .+\+(\d+)(?:,(\d+))? @@/)
        next unless match

        hunk_start = match[1].to_i
        hunk_count = (match[2] || 1).to_i
        return hunk.strip if target_line.between?(hunk_start, hunk_start + hunk_count)
      end
      nil
    end

    def pos_field(pos, field)
      if pos.respond_to?(field)
        pos.send(field)
      elsif pos.is_a?(Hash)
        pos[field.to_s] || pos[field]
      end
    end
  end
end
