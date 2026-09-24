# frozen_string_literal: true

module Autodev
  # Does every project that declares a `review_skill` actually carry it?
  # (Autodev #81, the ticket's option 2.)
  #
  # The tension the ticket states is real: a `SKILL.md` lives in the project's
  # repository, so the configuration form can only ever check the *shape* of the
  # name. But it is knowable from outside, which turns the check into one
  # question ("does this path exist on this ref") that GitLab's repository-files
  # endpoint answers in a single request.
  #
  # This class used to justify its ref by calling the target branch "a faithful
  # proxy" for the MR branch, on the grounds that autodev cuts the one from the
  # other. That was true at the cut and false from the first commit after it —
  # measured on 31/08/2026, 13 of 23 live branches carried no review skill at all
  # while their target branch did — and the review step meanwhile read the MR
  # branch, so the two disagreed in production (Autodev #89). There is no proxy
  # any more: the target branch is the branch that **decides**, for both readers,
  # and the reason is written down once in `ReviewSkillSource`.
  #
  # So the ticket's estimate of "one clone per project" is not the price. It is
  # one API call per *declaring* project per probe — two calls at the current
  # fleet size — and nothing is cloned, checked out or written to disk. A probe
  # is not every cycle any more: a healthy verdict is trusted while the next
  # cycle can still refresh it (Autodev #118, `trusted?`).
  #
  # Everything here fails **open**. `unknown` is a real verdict and is not
  # `missing`: an unreachable GitLab must never be read as a broken
  # configuration, which is Autodev #62's rule applied to a read whose answer
  # accuses the operator of a typo.
  #
  # The verdict is persisted, not recomputed by its reader. `HealthReport` is
  # passive by contract — it never calls GitLab, so it stays instant and safe for
  # an external probe to hammer — so this follows `UsageGate` exactly: the poll
  # cycle probes once, everyone downstream reads the recorded state.
  class ReviewSkillProbe
    KIND = 'review_skill'

    DEFAULT_POLL_INTERVAL = 300
    # Same reasoning as UsageGate's: a verdict is trusted for two poll intervals,
    # never less than ten minutes, so a tight interval cannot expire the state
    # between the probe and the card that reads it.
    TTL_POLL_INTERVALS = 2
    TTL_FLOOR = 600
    # `config/recurring.yml` fires the poll at most once a minute, whatever
    # `poll_interval` says, so the real period between two cycles is bounded by
    # the larger of the two. A bound, not a copy of the schedule's formula.
    MIN_CYCLE_PERIOD = 60

    class << self
      # Runs the live check and records the result. Called on every cycle by
      # AutodevPollJob, alongside the Claude-quota probe — and asks GitLab only
      # when the recorded verdict is no longer trusted.
      #
      # Returns the verdicts (an array of hashes) so a caller that wants them
      # immediately — a boot check, a test — does not have to read them back;
      # `nil` when the recorded verdict was still trusted and nothing was asked.
      #
      # It used to ask on every cycle, while the verdict it records is trusted for
      # `ttl` — 600 s against a 120 s cycle in production, where the probe was
      # 2 880 of 6 060 GitLab requests a day on 22/09/2026 (Autodev #118).
      def probe!(config:, projects:, client: nil, logger: nil)
        declaring = Array(projects).select { |project| skill_of(project) }
        return [] if declaring.empty?

        fleet = fleet_of(declaring)
        trusted?(fleet, config) ? nil : ask(config, declaring, fleet, client)
      rescue StandardError => e
        # An advisory check must never be what breaks a poll cycle.
        logger&.warn("[review_skill_probe] probe failed: #{e.class}: #{e.message}")
        []
      end

      # { missing: [verdict, …], checked: Integer, unknown: Integer, checked_at: Time|nil }.
      # `unknown` counts the declared skills GitLab did not answer about; a row
      # recorded before Autodev #118 carries no such key and reads as 0.
      # `checked_at` is nil when no usable verdict is on file (never probed,
      # unreadable, or stale) — which is exactly when the empty list is the
      # fail-open default rather than good news.
      def state(config: nil, now: Time.current)
        event = last_event
        return unknown if event.nil? || (now - event.created_at) > ttl(config)

        return unknown unless event.payload['missing'].is_a?(Array)

        state_of(event)
      rescue StandardError
        unknown
      end

      private

      def unknown = { missing: [], checked: 0, unknown: 0, checked_at: nil }

      def state_of(event)
        payload = event.payload
        { missing: payload['missing'], checked: payload['checked'].to_i, unknown: payload['unknown'].to_i,
          checked_at: event.created_at }
      end

      def ask(config, declaring, fleet, client)
        client ||= ::GitlabHelpers.build_gitlab_client(config['gitlab_url'], config['gitlab_token'])
        verdicts = declaring.map { |project| verdict_for(client, project) }
        record(verdicts, fleet)
        verdicts
      end

      def skill_of(project) = ::ReviewSkillSource.declared(project)

      # The question is not asked here (Autodev #89). It is
      # `ReviewSkillSource`'s, shared with the review step itself, because
      # asking it twice is what produced the defect that fix is about: this
      # class asked about the project's target branch, the review step looked in
      # a clone of the MR's *source* branch, and nothing said so — the probe
      # answered "present" and was right while the review gave the request up as
      # `review_skill_missing`.
      #
      # What stays here is the *shape* of a recorded fault: the project path, the
      # declared skill and the canonical path an operator should be told to add,
      # which are what the health card renders.
      def verdict_for(client, project)
        skill = skill_of(project)
        base = { path: project['path'], skill: skill, expected: MissingReviewSkillError.skill_path(skill) }
        base.merge(::ReviewSkillSource.verdict(client, project, skill).slice(:ref, :status))
      end

      # Only the faults are stored. The rest of the fleet is a count: nobody reads
      # a per-project "still fine", and these rows are machinery — written on a
      # clock, read only as the newest one, dropped past the retention window.
      #
      # `unknown` and `declared` are what `trusted?` reads: whether any verdict
      # was an outage, and which fleet the verdict is about.
      def record(verdicts, fleet)
        missing = verdicts.select { |v| v[:status] == ::ReviewSkillSource::MISSING }
        ActivityEvent.create(
          issue_id: nil, kind: KIND, level: missing.any? ? 'warn' : 'info',
          payload_json: JSON.generate(checked: verdicts.size, missing: missing,
                                      unknown: verdicts.count { |v| v[:status] == ::ReviewSkillSource::UNKNOWN },
                                      declared: fleet)
        )
      rescue StandardError
        nil # fire-and-forget: an unrecordable verdict just means "unknown"
      end

      # What a verdict is about: each declaring project, the skill it declares and
      # the target it declares. Sorted, and strings only, so it compares equal to
      # its own JSON round trip.
      def fleet_of(declaring)
        declaring.map do |project|
          [project['path'].to_s, skill_of(project), ::TargetBranch.declared(project).to_s]
        end.sort
      end

      # Whether the last verdict may stand for this cycle. Only good news is kept
      # — a `missing` is re-asked every cycle, because that is when an operator is
      # fixing the repository and watching the card, and an `unknown` is an outage
      # that keeps the cadence it always had. And only for the fleet it was taken
      # on: a changed declaration is what the project form's user is waiting on.
      #
      # Freshness is judged at the **next** cycle, with half a period to spare, so
      # the verdict is refreshed before it expires rather than after: the card
      # never reads `unknown` between two cycles while the poller runs. At
      # `poll_interval: 120` that re-asks every fourth cycle; at the default 300
      # `ttl` is two periods and every cycle re-asks. A row written before
      # Autodev #118 carries neither key and is not trusted.
      def trusted?(fleet, config)
        event = last_event
        return false if event.nil?

        return false unless event.payload.values_at('declared', 'missing', 'unknown') == [fleet, [], 0]

        period = [poll_interval(config), MIN_CYCLE_PERIOD].max
        (Time.current - event.created_at) + (period * 1.5) < ttl(config)
      rescue StandardError
        false
      end

      def last_event
        ActivityEvent.where(kind: KIND).order(created_at: :desc, id: :desc).first
      end

      def ttl(config) = [poll_interval(config) * TTL_POLL_INTERVALS, TTL_FLOOR].max

      def poll_interval(config)
        resolved = config || (defined?(::Web) && ::Web.config) || {}
        (resolved['poll_interval'] || DEFAULT_POLL_INTERVAL).to_i
      end
    end
  end
end
