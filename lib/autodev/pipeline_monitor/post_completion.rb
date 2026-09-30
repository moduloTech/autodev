# frozen_string_literal: true

class PipelineMonitor
  # Runs a project-configured post_completion command in a temporary clone.
  # Non-fatal: errors are logged and stored but do not prevent transition to done.
  #
  # Non-fatal is not silent (Autodev #94). The delivery happened — the work is
  # ready, the request IS done — so a failure changes no verdict: no
  # `needs_attention`, which means "given up" and would be the lie in the other
  # direction. What it lacked was a signal to the one person who can act on it,
  # the ticket's owner, who had to go and look at the dashboard to learn that a
  # deploy had failed. Every failure path therefore goes through `store_pc_error`,
  # which stores the error AND posts one comment on the ticket saying which
  # command failed and how — never its output, which is a deploy script's to
  # print and not the ticket's to publish.
  module PostCompletion
    def run_post_completion(issue, cmd)
      iid = issue.issue_iid
      return unless valid_pc_command?(issue, cmd)

      log "Running post_completion for issue ##{iid}: #{cmd.inspect}"
      work_dir = "/tmp/autodev_post_completion_#{@project_path.gsub('/', '_')}_#{iid}"
      execute_post_completion(issue, cmd, work_dir)
    ensure
      FileUtils.rm_rf(work_dir) if work_dir && Dir.exist?(work_dir)
    end

    def valid_pc_command?(issue, cmd)
      # `any?`: `[].all?(String)` is true, and an empty array reaches `Process.spawn`
      # as an `ArgumentError` (adversarial review).
      return true if cmd.is_a?(Array) && cmd.any? && cmd.all?(String)

      store_pc_error(issue, "post_completion config must be an array of strings, got: #{cmd.inspect}",
                     :post_completion_invalid_config, command: cmd.inspect)
      false
    end

    def execute_post_completion(issue, cmd, work_dir)
      return unless clone_for_post_completion(issue, cmd, work_dir)

      env = post_completion_env(issue)
      timeout = (@project_config['post_completion_timeout'] || ::Config::POST_COMPLETION_TIMEOUT).to_i
      run_pc_with_timeout(issue, cmd, work_dir, env, timeout)
    end

    # A clone that fails used to raise out of the job before `post_completion_done!`,
    # leaving the row in `running_post_completion` until the next restart and no
    # error written anywhere — the quietest of the failures (Autodev #94). The
    # message is already scrubbed of the clone URL's token by `ShellHelpers.run_cmd`.
    def clone_for_post_completion(issue, cmd, work_dir)
      clone_and_checkout(work_dir, issue.branch_name)
      true
    rescue GitError => e
      store_pc_error(issue, "post_completion could not clone #{issue.branch_name}: #{e.message}",
                     :post_completion_clone_failed, command: cmd.join(' '), branch: issue.branch_name.to_s)
      false
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
      pid = spawn_pc(issue, cmd, work_dir, env, { out: stdout_w, err: stderr_w })
      return unless pid

      [stdout_w, stderr_w].each(&:close)
      threads = { out: Thread.new { stdout_r.read }, err: Thread.new { stderr_r.read } }
      wait_for_process(issue, cmd, pid, threads, timeout)
    ensure
      # The write ends too: a spawn that raised never reached the line closing them.
      [stdout_r, stdout_w, stderr_r, stderr_w].each { |io| io&.close }
    end

    # `Process.spawn` raises before any exit status exists when the command is
    # missing or not executable (`Errno::ENOENT`, `Errno::EACCES`) — the likeliest
    # misconfiguration of all, and one the exit/timeout handlers never see. It is
    # a failure of the command like the others, so it takes the same sink. The
    # rescue covers the spawn alone: a `SystemCallError` from the wait or the kill
    # is not "could not start". `ArgumentError` is the same event in another class:
    # an argument carrying a NUL byte is refused before any `exec` (adversarial
    # review).
    def spawn_pc(issue, cmd, work_dir, env, pipes)
      Process.spawn(env, *cmd, chdir: work_dir, in: :close, **pipes, pgroup: true)
    rescue SystemCallError, ArgumentError => e
      store_pc_error(issue, "post_completion could not start: #{e.class}: #{e.message}",
                     :post_completion_not_started, command: cmd.join(' '), reason: Redactor.scrub(e.message))
      nil
    end

    def wait_for_process(issue, cmd, pid, threads, timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          return handle_pc_timeout(issue, cmd, pid, threads, timeout)
        end

        _pid, status = Process.wait2(pid, Process::WNOHANG)
        return handle_exit(issue, cmd, status, threads) if status

        sleep 1
      end
    end

    def handle_pc_timeout(issue, cmd, pid, threads, timeout)
      kill_process(pid)
      out, err = threads[:out].value, threads[:err].value # rubocop:disable Style/ParallelAssignment
      store_pc_error(issue,
                     "post_completion timed out after #{timeout}s\nstdout: #{out[0, 1000]}\nstderr: #{err[0, 1000]}",
                     :post_completion_timed_out, command: cmd.join(' '), timeout: timeout)
    end

    def handle_exit(issue, cmd, status, threads)
      return log("Issue ##{issue.issue_iid}: post_completion succeeded") if status.success?

      out, err = threads[:out].value, threads[:err].value # rubocop:disable Style/ParallelAssignment
      output = "stdout: #{out[0, 1000]}\nstderr: #{err[0, 1000]}"
      return store_pc_killed(issue, cmd, status, output) if status.signaled?

      store_pc_error(issue, "post_completion exited #{status.exitstatus}\n#{output}",
                     :post_completion_exited, command: cmd.join(' '), status: status.exitstatus.to_s)
    end

    # A command ended by a signal (an OOM kill, a crash) has no exit code —
    # `exitstatus` is nil — so it would have read "exited with code ." here.
    def store_pc_killed(issue, cmd, status, output)
      signal = Signal.signame(status.termsig) || status.termsig.to_s
      store_pc_error(issue, "post_completion killed by SIG#{signal}\n#{output}",
                     :post_completion_killed, command: cmd.join(' '), signal: "SIG#{signal}")
    end

    def kill_process(pid)
      Process.kill('TERM', -pid)
      sleep 3
      Process.kill('KILL', -pid) rescue nil # rubocop:disable Style/RescueModifier
      Process.wait(pid) rescue nil # rubocop:disable Style/RescueModifier
    end

    # The one sink for every failure: the column the dashboard and `/healthz`
    # already read, and the comment nobody had to go looking for. `vars` carries
    # what the comment may say — the command (scrubbed: an argument may hold a
    # credential) and the outcome's one figure — and never the stdout/stderr the
    # stored message keeps.
    #
    # The write is conditional on the row still running its hook (concurrency
    # review): a dashboard Reset accepts a row in `running_post_completion`, and
    # it lifts the reservation and the error (`Issue::POST_COMPLETION_CLEARED`).
    # Writing unconditionally put the old delivery's failure back onto the reset
    # row, and announced it on the ticket. Nothing written, nothing said.
    def store_pc_error(issue, error_msg, key, **vars)
      log_error "Issue ##{issue.issue_iid}: #{error_msg}"
      written = Issue.where(id: issue.id, status: 'running_post_completion')
                     .update_all(post_completion_error: error_msg)
      return log("Issue ##{issue.issue_iid}: row left running_post_completion, failure not recorded") if written.zero?

      notify_localized(issue.issue_iid, key, suffix: :post_completion_failed_footer, mr_url: issue.mr_url,
                                             **vars.merge(command: Redactor.scrub(vars[:command].to_s)))
    end
  end
end
