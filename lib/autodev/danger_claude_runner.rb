# frozen_string_literal: true

require_relative 'label_manager'
require_relative 'issue_notifier'
require_relative 'process_runner'
require_relative 'rate_limit_detector'
require_relative 'repo_operations'

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

  include ShellHelpers
  include LabelManager
  include IssueNotifier
  include ProcessRunner
  include RepoOperations

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
    @last_session_id = nil
  end

  # rubocop:disable Metrics/ParameterLists
  def danger_claude_prompt(work_dir, prompt, label: '-p', agent: nil, model: nil, resume: nil)
    args = dc_global_args(model_default: model)
    args.push('-r', resume) if resume
    args.push('-a', agent) if agent
    args += ['-p', prompt]
    log_dc_prompt(prompt, agent)
    out, err, ok = run_with_timeout('danger-claude', args, chdir: work_dir, label: label)
    text = capture_session_and_text(out)
    RateLimitDetector.check!(text, err)
    raise ImplementationError, dc_error_msg('-p', text, err) unless ok

    text
  end
  # rubocop:enable Metrics/ParameterLists

  def log_dc_prompt(prompt, agent)
    prefix = agent ? "danger-claude -a #{agent} -p" : 'danger-claude -p'
    @logger.debug("#{prefix} prompt:\n#{prompt}", project: @project_path)
  end

  def danger_claude_commit(work_dir, label: '-c', resume: nil)
    args = dc_global_args
    args.push('-r', resume) if resume
    args += ['-c']
    out, err, ok = run_with_timeout('danger-claude', args, chdir: work_dir, label: label)
    text = capture_session_and_text(out)
    RateLimitDetector.check!(text, err)
    raise ImplementationError, dc_error_msg('-c', text, err) unless ok

    text
  end

  def dc_error_msg(mode, text, err)
    "danger-claude #{mode} failed:\nstdout: #{text[0, 500]}\nstderr: #{err[0, 500]}"
  end

  # claude --output-format json returns one JSON envelope: { "result": "...", "session_id": "...", ... }.
  # Defensive: if claude (or an older danger-claude) didn't honor --output-format,
  # fall back to treating stdout as raw text with no session_id and surface a warn
  # event on the current issue so the operator sees session reuse silently degraded.
  def capture_session_and_text(raw)
    return raw.to_s if raw.nil? || raw.strip.empty?

    parsed = JSON.parse(raw.strip)
    return parse_failed(raw) unless parsed.is_a?(Hash)

    @last_session_id = parsed['session_id'] if parsed['session_id']
    parsed['result'].to_s
  rescue JSON::ParserError
    parse_failed(raw)
  end

  def parse_failed(raw)
    @logger&.warn('danger-claude output not JSON, session reuse disabled for this call', project: @project_path)
    log_activity_warn(:dc_parse_failed)
    raw
  end

  # Build global danger-claude args from config (project overrides global).
  # `model_default` is the per-call recommended model (e.g. 'haiku' for cheap JSON tasks).
  # Resolution order: project config > global config > per-call default.
  # Always emits `--output-format json` so callers can parse `session_id` for chaining.
  def dc_global_args(model_default: nil)
    args = ['-v', '/tmp', '--output-format', 'json']
    args.concat(ChromeDevtoolsInjector.dc_args) if Config.project_has_exposed_ports?(@project_config)
    @port_mappings = PortAllocator.allocate(@project_config)
    args.concat(PortAllocator.dc_port_args(@port_mappings))
    model = @project_config['model'] || @config['model'] || model_default
    effort = @project_config['effort'] || @config['effort']
    args.push('-m', model) if model
    args.push('-e', effort) if effort
    args
  end

  def safe_mark_failed!(issue)
    issue.mark_failed!
  rescue AASM::InvalidTransition
    issue.update(status: 'error')
  end

  def log(msg)
    @logger.info(msg, project: @project_path)
  end

  def log_error(msg)
    @logger.error(msg, project: @project_path)
  end
end
