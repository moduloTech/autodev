# frozen_string_literal: true

class PipelineMonitor
  # Runs a project-configured post_completion command in a temporary clone.
  # Non-fatal: errors are logged and stored but do not prevent transition to done.
  module PostCompletion
    def run_post_completion(issue, cmd)
      iid = issue.issue_iid

      unless cmd.is_a?(Array) && cmd.all?(String)
        store_pc_error(issue, "post_completion config must be an array of strings, got: #{cmd.inspect}")
        return
      end

      log "Running post_completion for issue ##{iid}: #{cmd.inspect}"
      work_dir = "/tmp/autodev_post_completion_#{@project_path.gsub('/', '_')}_#{iid}"
      execute_post_completion(issue, cmd, work_dir)
    ensure
      FileUtils.rm_rf(work_dir) if work_dir && Dir.exist?(work_dir)
    end

    def execute_post_completion(issue, cmd, work_dir)
      clone_and_checkout(work_dir, issue.branch_name)
      env = post_completion_env(issue)
      timeout = (@project_config['post_completion_timeout'] || 300).to_i
      run_pc_with_timeout(issue, cmd, work_dir, env, timeout)
    end

    def post_completion_env(issue)
      DangerClaudeRunner::CLEAN_ENV.merge(
        'AUTODEV_ISSUE_IID' => issue.issue_iid.to_s,
        'AUTODEV_MR_IID' => issue.mr_iid.to_s,
        'AUTODEV_BRANCH_NAME' => issue.branch_name.to_s
      )
    end

    def run_pc_with_timeout(issue, cmd, work_dir, env, timeout)
      stdout_r, stdout_w = IO.pipe
      stderr_r, stderr_w = IO.pipe
      pid = Process.spawn(env, *cmd, chdir: work_dir, in: :close, out: stdout_w, err: stderr_w, pgroup: true)
      stdout_w.close; stderr_w.close # rubocop:disable Style/Semicolon
      threads = { out: Thread.new { stdout_r.read }, err: Thread.new { stderr_r.read } }
      wait_for_process(issue, pid, threads, timeout)
    ensure
      stdout_r&.close; stderr_r&.close # rubocop:disable Style/Semicolon
    end

    def wait_for_process(issue, pid, threads, timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          return handle_pc_timeout(issue, pid, threads, timeout)
        end

        _pid, status = Process.wait2(pid, Process::WNOHANG)
        return handle_exit(issue, status, threads) if status

        sleep 1
      end
    end

    def handle_pc_timeout(issue, pid, threads, timeout)
      kill_process(pid)
      out, err = threads[:out].value, threads[:err].value # rubocop:disable Style/ParallelAssignment
      store_pc_error(issue,
                     "post_completion timed out after #{timeout}s\nstdout: #{out[0, 1000]}\nstderr: #{err[0, 1000]}")
    end

    def handle_exit(issue, status, threads)
      return log("Issue ##{issue.issue_iid}: post_completion succeeded") if status.success?

      out, err = threads[:out].value, threads[:err].value # rubocop:disable Style/ParallelAssignment
      store_pc_error(issue,
                     "post_completion exited #{status.exitstatus}\nstdout: #{out[0, 1000]}\nstderr: #{err[0, 1000]}")
    end

    def kill_process(pid)
      Process.kill('TERM', -pid)
      sleep 3
      Process.kill('KILL', -pid) rescue nil # rubocop:disable Style/RescueModifier
      Process.wait(pid) rescue nil # rubocop:disable Style/RescueModifier
    end

    def store_pc_error(issue, error_msg)
      log_error "Issue ##{issue.issue_iid}: #{error_msg}"
      Issue.where(id: issue.id).update(post_completion_error: error_msg)
    end
  end
end
