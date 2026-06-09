# frozen_string_literal: true

module Autodev
  # Delegating logger that swallows the `project:`/`mr_iid:`/etc. kwargs the
  # legacy `AppLogger` (lib/autodev/logger.rb) accepted on `info`/`warn`/
  # `error`/`debug`. Rails' built-in `Logger`/`BroadcastLogger` doesn't grok
  # those — passing them straight through raises `ArgumentError: wrong
  # number of arguments (given 2, expected 0..1)`.
  #
  # Wraps the ActiveJob `logger` before it's handed to the workflow classes
  # (`IssueProcessor`, `MrFixer`, `PipelineMonitor`, `PollDispatcher`, ...).
  # Forwards every other method to the underlying logger via `SimpleDelegator`.
  class JobLogger < SimpleDelegator
    %i[info warn error debug fatal unknown].each do |level|
      define_method(level) do |msg = nil, **_vars, &block|
        __getobj__.public_send(level, msg, &block)
      end
    end
  end
end
