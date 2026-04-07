# frozen_string_literal: true

require_relative 'label_manager'
require_relative 'issue_notifier'
require_relative 'process_runner'

# Shared module for IssueProcessor, MrFixer, and PipelineMonitor.
# Provides danger-claude execution, git clone, timeout handling,
# issue notification, and logging.
#
# Including classes must call `init_runner(...)` in their initialize.
module DangerClaudeRunner
  # Env hash that explicitly unsets all Bundler-related vars in child processes.
  CLEAN_ENV = %w[
    BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_BIN_PATH BUNDLE_APP_CONFIG
    BUNDLE_ORIG_GEMFILE BUNDLER_VERSION BUNDLER_ORIG_BUNDLER_VERSION
    BUNDLER_SETUP RUBYOPT RUBYLIB
  ].to_h { |var| [var, nil] }.freeze

  RATE_LIMIT_PATTERN = /you've hit your limit|rate limit|usage limit/i
  RATE_LIMIT_RESET_PATTERN = /resets?\s+(\d{1,2})(am|pm)\s*\(UTC\)/i

  include ShellHelpers
  include LabelManager
  include IssueNotifier
  include ProcessRunner

  private

  def init_runner(client:, config:, project_config:, logger:, token:)
    @client         = client
    @config         = config
    @project_config = project_config
    @logger         = logger
    @token          = token
    @project_path   = project_config['path']
    @gitlab_url     = config['gitlab_url']
    @dc_stdout      = +''
    @dc_stderr      = +''
  end

  def danger_claude_prompt(work_dir, prompt, label: '-p', agent: nil)
    args = dc_global_args + ['-p', prompt]
    log_dc_prompt(prompt, agent)
    out, err, ok = run_with_timeout('danger-claude', args, chdir: work_dir, label: label)
    unless ok
      check_rate_limit!(out, err)
      raise ImplementationError, "danger-claude -p failed:\nstdout: #{out[0, 500]}\nstderr: #{err[0, 500]}"
    end
    check_rate_limit!(out, err)
    out
  end

  def log_dc_prompt(prompt, agent)
    if agent
      @logger.debug("danger-claude -a #{agent} -p prompt:\n#{prompt}", project: @project_path)
    else
      @logger.debug("danger-claude -p prompt:\n#{prompt}", project: @project_path)
    end
  end

  def danger_claude_commit(work_dir, label: '-c')
    out, err, ok = run_with_timeout('danger-claude', dc_global_args + ['-c'], chdir: work_dir, label: label)
    unless ok
      check_rate_limit!(out, err)
      raise ImplementationError, "danger-claude -c failed:\nstdout: #{out[0, 500]}\nstderr: #{err[0, 500]}"
    end
    out
  end

  def check_rate_limit!(stdout, stderr)
    combined = "#{stdout}\n#{stderr}"
    return unless combined.match?(RATE_LIMIT_PATTERN)

    reset_time = parse_reset_time(combined)
    raise RateLimitError.new(
      "API rate limit reached#{" (resets #{reset_time.strftime('%H:%M UTC')})" if reset_time}", reset_time: reset_time
    )
  end

  def parse_reset_time(text)
    match = text.match(RATE_LIMIT_RESET_PATTERN)
    return nil unless match

    hour = convert_to_24h(match[1].to_i, match[2].downcase)
    now = Time.now.utc
    reset = Time.utc(now.year, now.month, now.day, hour, 0, 0)
    reset += 86_400 if reset <= now # next day if already past
    reset
  end

  def convert_to_24h(hour, ampm)
    hour += 12 if ampm == 'pm' && hour != 12
    hour = 0 if ampm == 'am' && hour == 12
    hour
  end

  # Build global danger-claude args from config (project overrides global).
  def dc_global_args
    args = ['-v', '/tmp']
    ChromeDevtoolsInjector.volume_args.each { |vol| args.push('-v', vol) } if @config['chrome_devtools']
    model = @project_config['model'] || @config['model']
    effort = @project_config['effort'] || @config['effort']
    args.push('-m', model) if model
    args.push('-e', effort) if effort
    args
  end

  def clone_and_checkout(work_dir, branch)
    FileUtils.rm_rf(work_dir)

    uri = URI.parse(@gitlab_url)
    host_port = uri.port && ![80, 443].include?(uri.port) ? "#{uri.host}:#{uri.port}" : uri.host
    clone_url = "#{uri.scheme}://oauth2:#{@token}@#{host_port}/#{@project_path}.git"

    clone_depth = @project_config['clone_depth'] || 1
    cmd = %w[git clone]
    cmd += ['--depth', clone_depth.to_s] if clone_depth.positive?
    cmd += ['--branch', branch]
    cmd += [clone_url, work_dir]

    run_cmd(cmd)
  end

  def log(msg)
    @logger.info(msg, project: @project_path)
  end

  def log_error(msg)
    @logger.error(msg, project: @project_path)
  end
end
