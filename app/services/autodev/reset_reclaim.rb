# frozen_string_literal: true

module Autodev
  # The GitLab half of an operator's reset (Autodev #93/#106, design §6):
  # reclaims the assignment and reposes the working label for the request the
  # dashboard's *Réinitialiser* button or the `--reset` CLI is resuming.
  #
  # Deliberately not inside `Issue.reset_for_retry!` itself: that method is
  # also called by `revive_stalled!` and `recover_on_startup!` — automatic
  # recoveries of a row that was never handed back, which must reclaim
  # nothing. The split follows the existing `reset_budget:` line: that
  # parameter already marks an operator-driven reset apart from an automatic
  # one, and this class is invoked by the same two callers that pass
  # `reset_budget: true` — `IssuesController#reset` and the `--reset` CLI —
  # never by the model method.
  #
  # A no-op for a request this ticket does not concern: one that was never
  # abandoned (`needs_attention` false — the plain `error` reset, which never
  # lost the assignment because `abandon_issue` is the only writer of
  # `hand_ticket_back` and `error` never goes through it) or one that carries
  # no merge request yet (every abandon path fires from a post-MR state, so
  # `needs_attention` implies `mr_iid` today — kept as a guard rather than an
  # assumption a future abandon path is free to break silently).
  #
  # Ordering follows the design's §5: the label first (no `clear_scope:` —
  # design §3, that option's one caller is the sweep, which alone has asked
  # `untouched_since_giveup?` first), then the assignment with its read-back.
  # If the assignment cannot be landed, the label is put back and the error
  # propagates — the caller must not call `Issue.reset_for_retry!` on a
  # half-applied reclaim. Where no GitLab client can be built at all, the
  # gesture is refused before anything is written: `GitlabHelpers.build_gitlab_client`
  # already raises `ConfigError` for that, and it is left to propagate here
  # rather than rescued.
  class ResetReclaim
    def self.perform(issue, config:, logger: nil)
      new(config: config, logger: logger).perform(issue)
    end

    def initialize(config:, logger: nil)
      @config = config
      @logger = logger
    end

    def perform(issue)
      return unless issue.needs_attention? && issue.mr_iid

      client = ::GitlabHelpers.build_gitlab_client(@config['gitlab_url'], @config['gitlab_token'])
      router = router_for(issue.project_path)
      router.repose_working_label(issue, client)
      reclaim(issue, client, router)
    end

    private

    def reclaim(issue, client, router)
      ::Autodev::TicketReclaim.new(client: client, logger: @logger)
                              .reclaim!(issue, message_key: :reclaim_operator_reset)
    rescue StandardError
      router.restore_attention_label(issue, client)
      raise
    end

    def router_for(path)
      project_config = ::Project.runtime_configs(@config['projects']).find { |cfg| cfg['path'] == path } ||
                       raise(::ConfigError, "no project configuration for #{path}")
      ::PollRouter.new(config: @config, project_config: project_config, logger: @logger,
                       token: @config['gitlab_token'], pool: nil)
    end
  end
end
