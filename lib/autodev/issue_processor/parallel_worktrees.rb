# frozen_string_literal: true

class IssueProcessor
  # Worktree setup and cleanup for parallel agent execution.
  module ParallelWorktrees
    private

    def setup_test_worktree(work_dir)
      test_wt = "#{work_dir}_tests"
      run_cmd(['git', 'worktree', 'add', test_wt, 'HEAD'], chdir: work_dir)
      SkillsInjector.inject(test_wt, logger: @logger, project_path: @project_path)
      copy_agents(work_dir, test_wt)
      test_wt
    end

    def setup_parallel_worktrees(work_dir, tasks, context)
      tasks.each_with_index.map do |task, idx|
        wt_path = "#{work_dir}_task_#{idx}"
        run_cmd(['git', 'worktree', 'add', wt_path, 'HEAD'], chdir: work_dir)
        SkillsInjector.inject(wt_path, logger: @logger, project_path: @project_path)
        copy_agents(work_dir, wt_path)
        GitlabHelpers.write_context_file(nil, @current_branch_name, context)
        { path: wt_path, task: task }
      end
    end

    def copy_agents(src_dir, dst_dir)
      agents_src = File.join(src_dir, '.claude', 'agents')
      return unless Dir.exist?(agents_src)

      agents_dst = File.join(dst_dir, '.claude', 'agents')
      FileUtils.mkdir_p(agents_dst)
      FileUtils.cp_r(Dir.glob(File.join(agents_src, '*')), agents_dst)
    end

    def cleanup_test_worktree(test_worktree, work_dir)
      return unless test_worktree

      GitlabHelpers.cleanup_context_file(nil, @current_branch_name)
      return unless Dir.exist?(test_worktree)

      run_cmd_status(['git', 'worktree', 'remove', '--force', test_worktree], chdir: work_dir)
      FileUtils.rm_rf(test_worktree)
    end

    def cleanup_worktrees(worktrees, work_dir)
      worktrees.each do |wt|
        GitlabHelpers.cleanup_context_file(nil, @current_branch_name)
        next unless wt[:path] && Dir.exist?(wt[:path])

        run_cmd_status(['git', 'worktree', 'remove', '--force', wt[:path]], chdir: work_dir)
        FileUtils.rm_rf(wt[:path])
      end
    end

    def raise_if_all_failed(errors, tasks)
      return unless errors.size == tasks.size

      raise ImplementationError, "All parallel agents failed: #{errors.map do |e|
        "#{e[:task]}: #{e[:error].message}"
      end.join('; ')}"
    end
  end
end
