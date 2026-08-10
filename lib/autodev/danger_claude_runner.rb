# frozen_string_literal: true

require_relative 'auth_failure_detector'
require_relative 'label_manager'
require_relative 'issue_notifier'
require_relative 'process_runner'
require_relative 'rate_limit_detector'
require_relative 'repo_operations'
require_relative 'repo_rebaser'

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
  include RepoRebaser

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

  # rubocop:disable Metrics/ParameterLists, Metrics/MethodLength
  def danger_claude_prompt(work_dir, prompt, label: '-p', agent: nil, model: nil, resume: nil)
    args = dc_global_args(model_default: model)
    args.push('-r', resume) if resume
    args.push('-a', agent) if agent
    args += ['-p', prompt]
    log_dc_prompt(prompt, agent)
    dc_heartbeat!(label)
    out, err, ok = run_with_timeout('danger-claude', args, chdir: work_dir, label: label)
    text = capture_session_and_text(out)
    check_dc_failures!(text, err)
    raise ImplementationError, dc_error_msg('-p', text, err) unless ok

    text
  end
  # rubocop:enable Metrics/ParameterLists, Metrics/MethodLength

  def log_dc_prompt(prompt, agent)
    prefix = agent ? "danger-claude -a #{agent} -p" : 'danger-claude -p'
    @logger.debug("#{prefix} prompt:\n#{prompt}", project: @project_path)
  end

  # The invariant dispatch_dormant_audit rests on (Autodev #50): a live worker's
  # silence must stay under HealthReport#stuck_active_after, or the audit can
  # reposition a row while an IssueProcessJob holds the concurrency lock on it —
  # silently, since the model runs with `whiny_transitions: false`.
  #
  # Business events do not provide that bound (PipelineFixer: one event per
  # state, two calls per failed job), so liveness is recorded per call, here,
  # where every issue-scoped danger-claude call funnels through. Two bypasses sit
  # outside that guarantee, both not issue-scoped today: Autospec::ProjectBriefer
  # (raw Open3.capture3, no timeout) and Autodev::UsageChecker's probe. Neither
  # is broken by that — this class only bounds silence on rows the dormant audit
  # can touch — but a future issue-scoped call written in ProjectBriefer's style
  # would not be covered.
  #
  # Before the call, not after: the clock resets when the call starts, so the
  # longest possible gap is one call's dc_timeout plus loop overhead — whatever
  # the surrounding loop does.
  def dc_heartbeat!(label)
    ActivityLogger.heartbeat!(@dc_issue, label)
  end

  def danger_claude_commit(work_dir, label: '-c', resume: nil)
    args = dc_global_args
    args.push('-r', resume) if resume
    args += ['-c']
    dc_heartbeat!(label)
    out, err, ok = run_with_timeout('danger-claude', args, chdir: work_dir, label: label)
    text = capture_session_and_text(out)
    check_dc_failures!(text, err)
    raise ImplementationError, dc_error_msg('-c', text, err) unless ok

    text
  end

  def dc_error_msg(mode, text, err)
    "danger-claude #{mode} failed:\nstdout: #{text[0, 500]}\nstderr: #{err[0, 500]}"
  end

  # Raises a typed error (RateLimitError / AuthenticationError) when danger-claude
  # output carries a known fatal signature, so the workers can react specifically
  # instead of treating it as a generic ImplementationError.
  def check_dc_failures!(text, err)
    RateLimitDetector.check!(text, err)
    AuthFailureDetector.check!(text, err)
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
