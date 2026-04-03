# frozen_string_literal: true

class IssueProcessor
  # Merges files from git worktrees back into the main work directory.
  module WorktreeMerger
    private

    def merge_worktree_files(worktree_path, work_dir, task_name)
      files = collect_changed_files(worktree_path)

      if files.empty?
        log "Agent '#{task_name}' produced no changes"
        return
      end

      log "Merging #{files.size} file(s) from agent '#{task_name}'..."
      copy_files(files, worktree_path, work_dir)
    end

    def merge_test_files(test_worktree, work_dir)
      files = collect_changed_files(test_worktree)

      if files.empty?
        log 'Test-writer produced no changes'
        return
      end

      log "Merging #{files.size} test file(s) from worktree..."
      copy_files(files, test_worktree, work_dir)
      log "Merged test files: #{files.join(', ')}"
    end

    def collect_changed_files(worktree_path)
      changed, _err, ok = run_cmd_status(['git', 'diff', '--name-only', 'HEAD'], chdir: worktree_path)
      untracked, _err, ok2 = run_cmd_status(['git', 'ls-files', '--others', '--exclude-standard'], chdir: worktree_path)

      files = []
      files += parse_file_list(changed) if ok
      files += parse_file_list(untracked) if ok2
      files.uniq
    end

    def parse_file_list(output)
      output.split("\n").map(&:strip).reject(&:empty?)
    end

    def copy_files(files, src_dir, dst_dir)
      files.each do |file|
        src = File.join(src_dir, file)
        dst = File.join(dst_dir, file)
        next unless File.exist?(src)

        FileUtils.mkdir_p(File.dirname(dst))
        FileUtils.cp(src, dst)
      end
    end
  end
end
