# frozen_string_literal: true

module Autodev
  # Does every project that declares a `review_skill` actually carry it?
  # (Autodev #81, the ticket's option 2.)
  #
  # The tension the ticket states is real: a `SKILL.md` lives in the project's
  # repository, at the revision of the MR's branch, so the configuration form can
  # only ever check the *shape* of the name. But "at the revision of the MR
  # branch" is not the same as "unknowable until the clone". Autodev creates that
  # branch off the project's target branch, so the target branch is a faithful
  # proxy, and it is knowable from outside — which turns the check into one
  # question ("does this path exist on this ref") that GitLab's repository-files
  # endpoint answers in a single request.
  #
  # So the ticket's estimate of "one clone per project" is not the price. It is
  # one API call per *declaring* project per cycle — two calls at the current
  # fleet size — and nothing is cloned, checked out or written to disk.
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

    # A skill *directory* name. Anything else cannot be a path segment under
    # `.claude/skills/`, so it is answered without asking GitLab — which is also
    # where the ticket's option 3 (a shape check on the form) ends up, in the one
    # place where it produces a verdict rather than a second opinion.
    NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

    DEFAULT_POLL_INTERVAL = 300
    # Same reasoning as UsageGate's: a verdict is trusted for two poll intervals,
    # never less than ten minutes, so a tight interval cannot expire the state
    # between the probe and the card that reads it.
    TTL_POLL_INTERVALS = 2
    TTL_FLOOR = 600

    class << self
      # Runs the live check and records the result. Called once per cycle by
      # AutodevPollJob, alongside the Claude-quota probe.
      #
      # Returns the verdicts (an array of hashes) so a caller that wants them
      # immediately — a boot check, a test — does not have to read them back.
      def probe!(config:, projects:, client: nil, logger: nil)
        declaring = Array(projects).select { |project| skill_of(project) }
        return [] if declaring.empty?

        client ||= ::GitlabHelpers.build_gitlab_client(config['gitlab_url'], config['gitlab_token'])
        verdicts = declaring.map { |project| verdict_for(client, project) }
        record(verdicts)
        verdicts
      rescue StandardError => e
        # An advisory check must never be what breaks a poll cycle.
        logger&.warn("[review_skill_probe] probe failed: #{e.class}: #{e.message}")
        []
      end

      # { missing: [verdict, …], checked: Integer, checked_at: Time|nil }.
      # `checked_at` is nil when no usable verdict is on file (never probed,
      # unreadable, or stale) — which is exactly when the empty list is the
      # fail-open default rather than good news.
      def state(config: nil, now: Time.current)
        event = last_event
        return unknown if event.nil? || (now - event.created_at) > ttl(config)

        payload = event.payload
        missing = payload['missing']
        return unknown unless missing.is_a?(Array)

        { missing: missing, checked: payload['checked'].to_i, checked_at: event.created_at }
      rescue StandardError
        unknown
      end

      private

      def unknown = { missing: [], checked: 0, checked_at: nil }

      # `.presence`, the same reading `Reviewer#launch_review` gives it: `''` is
      # truthy in Ruby and `to_project_config` emits every column of the row, so a
      # blank has to read as "no skill declared" here too, or the card reports a
      # fault on a project that takes the `mr-review` binary path.
      def skill_of(project) = project['review_skill'].to_s.strip.presence

      def verdict_for(client, project)
        path = project['path']
        skill = skill_of(project)
        base = { path: path, skill: skill, expected: MissingReviewSkillError.skill_path(skill) }
        return base.merge(ref: nil, status: 'missing') unless skill.match?(NAME)
        # SkillsInjector writes these into every clone whatever the repository
        # holds, so the review step will find them regardless.
        return base.merge(ref: nil, status: 'present') if ::SkillsInjector::SKILL_NAMES.include?(skill)

        resolve(client, base, project)
      end

      def resolve(client, base, project)
        ref = ref_for(client, project)
        return base.merge(ref: nil, status: 'unknown') if ref.nil?

        base.merge(ref: ref, status: layouts_status(client, base, ref))
      end

      # The same question the review step ends up asking, not an approximation of
      # it (Autodev #81, fix round 2). `SkillsInjector.skill_paths` lists every
      # layout a declared skill may take in the repository — the canonical
      # `<name>/SKILL.md` and the flat `<name>.md` that `migrate_legacy_skills`
      # moves into it inside the clone, before `skill_available?` looks. Asking
      # only about the first recorded a project that reviews perfectly well as
      # `missing`, which is the false accusation this class exists not to make.
      #
      # Canonical first, and the loop stops on the first hit, so the sobriety the
      # ticket asked for is kept where it counts: a fleet on the current layout —
      # which is both configured projects today — still costs one request per
      # declaring project per cycle. Only a repository that does not carry it pays
      # for the second question.
      #
      # `NotFound` on *every* layout is the only thing that may read as `missing`;
      # any other error on any of them is `unknown`, because a read that failed
      # answers nothing about the configuration (Autodev #62).
      def layouts_status(client, base, ref)
        ::SkillsInjector.skill_paths(base[:skill]).each do |path|
          return 'present' if file_on_ref?(client, base[:path], path, ref)
        rescue ::Gitlab::Error::NotFound
          next
        rescue StandardError
          return 'unknown'
        end
        'missing'
      end

      def file_on_ref?(client, project_path, file_path, ref)
        client.get_file(project_path, file_path, ref)
        true
      end

      # The branch autodev cuts its MR branch from, hence the revision the review
      # clone will carry. Unset means "the repository's default branch", the same
      # fallback `MrManager#create_mr` and `RepoRebaser` take.
      def ref_for(client, project)
        configured = project['target_branch'].to_s.strip
        return configured unless configured.empty?

        client.project(project['path']).default_branch
      rescue StandardError
        nil
      end

      # Only the faults are stored. The rest of the fleet is a count: nobody reads
      # a per-project "still fine", and these rows are machinery — written on a
      # clock, read only as the newest one, dropped past the retention window.
      def record(verdicts)
        ActivityEvent.create(
          issue_id: nil, kind: KIND,
          level: verdicts.any? { |v| v[:status] == 'missing' } ? 'warn' : 'info',
          payload_json: JSON.generate(checked: verdicts.size,
                                      missing: verdicts.select { |v| v[:status] == 'missing' })
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
