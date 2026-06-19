# frozen_string_literal: true

require_relative 'redactor'

# Convenience wrappers around Open3 for running shell commands.
module ShellHelpers
  module_function

  def run_cmd(cmd, chdir: nil, env: {})
    spawn_opts = {}
    spawn_opts[:chdir] = chdir if chdir
    out, err, status = Open3.capture3(env, *cmd, **spawn_opts)
    unless status.success?
      # Scrub before raising: the command embeds the GitLab PAT in clone/push
      # URLs, and this message flows into issues.error_message, the logs, and
      # the error comment posted on the GitLab issue (task #10).
      raise GitError, Redactor.scrub(
        "Command failed: #{cmd.is_a?(Array) ? cmd.join(' ') : cmd}\nstdout: #{out[0, 500]}\nstderr: #{err[0, 500]}"
      )
    end

    out.strip
  end

  def run_cmd_status(cmd, chdir: nil, env: {})
    spawn_opts = {}
    spawn_opts[:chdir] = chdir if chdir
    out, err, status = Open3.capture3(env, *cmd, **spawn_opts)
    [out.strip, err.strip, status.success?]
  end
end
