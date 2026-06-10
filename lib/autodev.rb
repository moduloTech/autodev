# frozen_string_literal: true

module Autodev
  VERSION = '1.0.0.alpha.9'
end

# Runtime gem dependencies. Idempotent — re-requiring a gem is a no-op.
# `sequel` and `sinatra/base` are intentionally absent — the Sequel-side
# `Issue`/`ActivityEvent` were retired in step 2 second half and the
# Sinatra `Web::Server` was retired in step 8. Phlex views now live under
# `app/components/web/views/` and load via Zeitwerk.
require 'aasm'
require 'gitlab'
require 'pastel'
require 'phlex'
require 'sqlite3'

require_relative 'autodev/errors'
require_relative 'autodev/logger'
require_relative 'autodev/config_validator'
require_relative 'autodev/project_validator'
require_relative 'autodev/app_validator'
require_relative 'autodev/app_instructions'
require_relative 'autodev/port_allocator'
require_relative 'autodev/screenshot_uploader'
require_relative 'autodev/config'
require_relative 'autodev/language_detector'
require_relative 'autodev/locales'
require_relative 'autodev/shell_helpers'
require_relative 'autodev/gitlab_helpers'
require_relative 'autodev/label_manager'
require_relative 'autodev/activity_logger'
require_relative 'autodev/issue_notifier'
require_relative 'autodev/process_runner'
require_relative 'autodev/rate_limit_detector'
require_relative 'autodev/repo_operations'
require_relative 'autodev/danger_claude_runner'
require_relative 'autodev/chrome_launcher'
require_relative 'autodev/chrome_devtools_injector'
require_relative 'autodev/skills_injector'
require_relative 'autodev/discussion_snapshot'
require_relative 'autodev/issue_processor'
require_relative 'autodev/mr_fixer'
require_relative 'autodev/pipeline_monitor'
require_relative 'autodev/usage_checker'
require_relative 'autodev/poll_router'
require_relative 'autodev/dashboard'
