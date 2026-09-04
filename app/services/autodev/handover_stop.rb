# frozen_string_literal: true

module Autodev
  # Autodev #102. `ExternalState` is a mixin for poll-cycle services carrying
  # `@client`, `@path`, `@project_config` and `@logger`; `IssueProcessJob` is not
  # one of those, and the question it needs — "has a human taken this ticket
  # back?" — already has exactly one definition there, together with the notice
  # and the terminal write that follow a yes.
  #
  # So this carries the ivars and nothing else. It deliberately has no logic of
  # its own: anything added here is an answer that can drift from
  # `PollDispatcher`'s, which is the fault Autodev #93 avoided by extracting
  # `UntouchedSinceGiveup` rather than writing the question twice.
  class HandoverStop
    include ExternalState

    def initialize(client:, path:, project_config:, logger:)
      @client = client
      @path = path
      @project_config = project_config
      @logger = logger
    end
  end
end
