# frozen_string_literal: true

module Autodev
  # Is the GitLab credential `mr-review` runs with still accepted? (Autodev #80.)
  #
  # The token in `~/.mr-review/config.yml` was revoked in April 2026. Every review
  # that went through the binary failed on `401 Token was revoked` from then until
  # 25/08, when both configured projects moved to a `review_skill` — 23 requests of
  # one project abandoned on `review_failures_exhausted`, the `mr_review` health
  # card firing on 25 distinct issues on 11/08, and the cause named in a log line
  # nobody connected to a credential. The point of this class is not the token,
  # which a human replaces; it is the four months.
  #
  # **Armed by the population, not by the clock.** A probe that tests a credential
  # nothing uses produces a card nobody acts on — the exact inverse of the rule
  # `HealthReport` states at `ACTIVE_STUCK_STATES` ("a state this card flags but
  # nothing can revive would be a card nobody can act on"). Today no project
  # reviews through the binary, so `probe!` returns before touching anything: no
  # GitLab call, no file read, no row. It arms itself on the first project
  # onboarded without a `review_skill`, which is the moment the fault comes back.
  # The predicate is `bin/autodev`'s own boot-warning predicate, shared rather
  # than restated (the lesson of Autodev #72 and #81).
  #
  # **Three verdicts, never two.** `alive`; `revoked` on 401/403 and nothing else;
  # `unknown` for everything that failed to answer — a 500, a timeout, an absent
  # or unparseable configuration file. Autodev #62's rule applied to a probe: a
  # read that did not happen accuses nobody.
  #
  # **Nothing it writes down is a secret.** The payload carries the *name* of the
  # configuration key the credential came from, never its value, because these
  # rows outlive the cycle and are read back by a health card.
  #
  # Passive on the reading side, like `UsageGate` and `ReviewSkillProbe`: the poll
  # cycle probes once and records; `HealthReport` never calls GitLab.
  class MrReviewTokenProbe
    KIND = 'mr_review_token'

    ALIVE = 'alive'
    REVOKED = 'revoked'
    UNKNOWN = 'unknown'
    STATUSES = [ALIVE, REVOKED, UNKNOWN].freeze

    # The only two answers that are a verdict on the credential itself. 401 is the
    # revoked/expired token; 403 is a token GitLab knows and refuses (scope
    # removed, user blocked). Everything else is the API's own weather.
    REVOKED_STATUSES = [401, 403].freeze

    # `mr-review`'s own configuration file, consulted only when autodev's
    # configuration declares no credential at all — i.e. only when the export
    # `Reviewer#mr_review_env` performs would be empty, and the binary would
    # genuinely fall through to it. Then it is the file that decides, so it is
    # the file the probe must read.
    CONFIG_PATH = File.expand_path('~/.mr-review/config.yml')
    CONFIG_KEY = 'gitlab_api_token'
    CONFIG_SOURCE = 'mr_review_config'

    DEFAULT_POLL_INTERVAL = 300
    # Same reasoning as UsageGate's and ReviewSkillProbe's: a verdict is trusted
    # for two poll intervals, never less than ten minutes, so a tight interval
    # cannot expire the state between the probe and the card that reads it.
    TTL_POLL_INTERVALS = 2
    TTL_FLOOR = 600

    class << self
      # Runs the live check and records the result. Called once per cycle by
      # AutodevPollJob, alongside the quota and review-skill probes.
      #
      # Returns the verdict hash, or nil when the fleet does not rely on the
      # binary (nothing was asked) or when the probe itself failed.
      def probe!(config:, projects:, client: nil, logger: nil, config_path: CONFIG_PATH)
        return nil unless relied_upon_by_any?(projects)

        verdict = verdict_for(config, client, config_path)
        record(verdict)
        verdict
      rescue StandardError => e
        # An advisory check must never be what breaks a poll cycle. Scrubbed: the
        # logger on this path does not scrub, and this call site holds a PAT.
        logger&.warn(::Redactor.scrub("[mr_review_token_probe] probe failed: #{e.class}: #{e.message}"))
        nil
      end

      # Does any project still review through the `mr-review` binary?
      #
      # `bin/autodev`'s `any_project_relies_on_mr_review?` delegates here, so the
      # boot warning and this probe cannot drift apart. And "is a skill declared"
      # is asked of `ReviewSkillSource`, not spelled again: a blank is not a
      # declaration (`''` is truthy in Ruby and `Project#to_project_config` emits
      # every column of the row), and this population must be the exact complement
      # of the one `Reviewer#launch_review` sends down the skill path. Three
      # spellings of that question survived the alpha-50 review — raw here, raw in
      # `SkillReviewer`, `.presence` in the reviewer — and only the shared one
      # trimmed, which is a divergence on a value with spaces around it.
      def relied_upon_by_any?(project_configs)
        Array(project_configs).any? { |project_config| ReviewSkillSource.declared(project_config).nil? }
      end

      # { status: 'alive'|'revoked'|'unknown', source: String|nil,
      #   checked_at: Time|nil }.
      #
      # `checked_at` is nil when no usable verdict is on file — never probed,
      # unreadable, or stale — which is exactly when `unknown` is the fail-open
      # default rather than news.
      def state(config: nil, now: Time.current)
        event = last_event
        return unknown if event.nil? || (now - event.created_at) > ttl(config)

        payload = event.payload
        return unknown unless STATUSES.include?(payload['status'])

        { status: payload['status'], source: payload['source'], checked_at: event.created_at }
      rescue StandardError
        unknown
      end

      private

      def unknown = { status: UNKNOWN, source: nil, checked_at: nil }

      def verdict_for(config, client, config_path)
        token, source = credential(config, config_path)
        # No credential to present is not a verdict on a credential.
        return { status: UNKNOWN, source: nil, reason: 'no_credential' } if token.nil?

        ask(client, config, token, source)
      end

      # The one call, and it is the one `IssueNotifier#assign_to_self` already
      # makes on every request: `GET /user`, the cheapest endpoint that answers
      # "does this token still authenticate".
      def ask(client, config, token, source)
        client ||= ::GitlabHelpers.build_gitlab_client(config['gitlab_url'], token)
        client.user
        { status: ALIVE, source: source, reason: nil }
      rescue ::Gitlab::Error::ResponseError => e
        http = response_status(e)
        { status: REVOKED_STATUSES.include?(http) ? REVOKED : UNKNOWN, source: source,
          reason: http ? "http_#{http}" : e.class.name }
      rescue StandardError => e
        { status: UNKNOWN, source: source, reason: e.class.name }
      end

      def response_status(error)
        Integer(error.response_status)
      rescue StandardError
        nil
      end

      # Autodev's configuration first, in the order `Reviewer#mr_review_env`
      # exports — the probe must test the credential the review will actually
      # present, not another one. `mr-review`'s own file is the last resort, for
      # the same reason it is the binary's: it only decides when nothing else did.
      def credential(config, config_path)
        declared = ::Config.mr_review_credential(config)
        return declared if declared

        [read_config_file(config_path), CONFIG_SOURCE]
      end

      # Unreadable, absent, off-shape: all nil, all `unknown` upstream. A file
      # this probe could not parse says nothing about the credential in it.
      def read_config_file(path)
        return nil unless File.exist?(path)

        data = YAML.safe_load_file(path, permitted_classes: [Symbol])
        return nil unless data.is_a?(Hash)

        data[CONFIG_KEY].to_s.strip.presence
      rescue StandardError
        nil
      end

      # The key's name, never its value: these rows are read back by a health
      # card and survive the cycle that wrote them.
      def record(verdict)
        ActivityEvent.create(
          issue_id: nil, kind: KIND, level: verdict[:status] == REVOKED ? 'warn' : 'info',
          payload_json: JSON.generate(status: verdict[:status], source: verdict[:source],
                                      reason: verdict[:reason])
        )
      rescue StandardError
        nil # fire-and-forget: an unrecordable verdict just means "unknown"
      end

      def last_event
        ActivityEvent.where(kind: KIND).order(created_at: :desc, id: :desc).first
      end

      def ttl(config)
        resolved = config || (defined?(::Web) && ::Web.config) || {}
        interval = (resolved['poll_interval'] || DEFAULT_POLL_INTERVAL).to_i
        [interval * TTL_POLL_INTERVALS, TTL_FLOOR].max
      end
    end
  end
end
