# frozen_string_literal: true

module Autodev
  VERSION = '0.8.4'
end

require_relative 'autodev/errors'
require_relative 'autodev/logger'
require_relative 'autodev/config_validator'
require_relative 'autodev/project_validator'
require_relative 'autodev/config'
require_relative 'autodev/language_detector'
require_relative 'autodev/locales'
require_relative 'autodev/shell_helpers'
require_relative 'autodev/gitlab_helpers'
require_relative 'autodev/issue_behavior'
require_relative 'autodev/database'
require_relative 'autodev/label_manager'
require_relative 'autodev/issue_notifier'
require_relative 'autodev/process_runner'
require_relative 'autodev/danger_claude_runner'
require_relative 'autodev/skills_injector'
require_relative 'autodev/issue_processor'
require_relative 'autodev/mr_fixer'
require_relative 'autodev/pipeline_monitor'
require_relative 'autodev/worker_pool'
require_relative 'autodev/poll_router'
require_relative 'autodev/dashboard'
require_relative 'autodev/poller'
