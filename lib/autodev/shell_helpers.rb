# frozen_string_literal: true

module ShellHelpers
  module_function

  def run_cmd(cmd, chdir: nil, env: {})
    spawn_opts = {}
    spawn_opts[:chdir] = chdir if chdir
    out, err, status = Open3.capture3(env, *cmd, **spawn_opts)
    unless status.success?
      raise GitError, "Command failed: #{cmd.is_a?(Array) ? cmd.join(" ") : cmd}\nstdout: #{out[0, 500]}\nstderr: #{err[0, 500]}"
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
