# frozen_string_literal: true

class PipelineMonitor
  INFRA_FAILURE_REASONS = %w[
    runner_system_failure stuck_or_timeout_failure scheduler_failure
    data_integrity_failure job_execution_timeout runner_unsupported
    stale_schedule unmet_prerequisites ci_quota_exceeded
    no_matching_runner trace_size_exceeded archived_failure
  ].freeze

  CODE_FAILURE_REASONS = %w[script_failure].freeze

  DEPLOY_JOB_PATTERN = /
    \b(deploy|release|publish|rollout|provision|terraform|ansible|
    helm|k8s|kubernetes|staging|production|review.?app)\b
  /ix

  CATEGORY_PATTERNS = {
    deploy: {
      names: DEPLOY_JOB_PATTERN,
      stages: DEPLOY_JOB_PATTERN,
      logs: /(?!)/ # never match on logs
    },
    test: {
      names: /\b(r?spec|test|minitest|cucumber|capybara|cypress|jest|mocha)\b/i,
      stages: /\btest/i,
      logs: /\b(failures?|failed examples?|tests?\s+failed|FAILED|assertion|expected\b.*\bgot\b|Error:.*spec)/i
    },
    lint: {
      names: /\b(rubocop|lint|eslint|stylelint|prettier|standardrb|brakeman|bundler.?audit|reek)\b/i,
      stages: /\blint|quality|static/i,
      logs: %r{\b(offenses?\s+detected|violations?|warning:.*\[\w+/\w+\]|rubocop)}i
    },
    build: {
      names: /\b(build|compile|assets|webpack|vite|bundle\s+install|yarn|npm)\b/i,
      stages: /\bbuild|prepare|install/i,
      logs: /\b(syntax error|cannot find|could not|compilation failed|LoadError|ModuleNotFoundError|gem.*not found)\b/i
    }
  }.freeze
end
