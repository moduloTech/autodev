# Plan — a finished row hands its ticket back (Autodev #126)

Spec: `docs/superpowers/specs/2026-09-28-a-finished-row-hands-its-ticket-back-design.md`.
Branch `fix/126-a-finished-row-hands-its-ticket-back` off `origin/master` (c4fac64).
Baseline: `mise x ruby@4.0.1 -- bundle exec rake test` → 2777 runs, 0 failures.

## Frozen contract (step 0, committed before the lanes start)

- `Issue#handback_target` → `displaced_assignee_id || issue_author_id`. `IssueNotifier#handback_target`
  delegates to it.
- `Autodev::LabelHandover::Verdict = Struct.new(:reason, :label, :actor_id)` — `actor_id` nil on a
  suspicion, set by `verdict` from the decisive event's `user.id`.
- `Autodev::CloseHandback.perform(issue, config:, logger:)` → a `Result = Struct.new(:outcome, :target_id, :target_name, :error)`; `target_name` is the
  assignee name GitLab returns from the edit (id as text when absent); `outcome` ∈ `:handed_back`, `:not_held`, `:no_target`, `:failed`.
- `Autodev::HeldTicketProbe` — `KIND = 'held_ticket'`, `INTERVAL = 15.minutes`, `TTL = 3 * INTERVAL`;
  `probe!(config:, projects:, client: nil, logger: nil, now: Time.current)`; `state(now:)` →
  `{ held: [{ 'id', 'path', 'iid', 'status' }], checked: Integer, unknown: Integer, checked_at: Time|nil }`.
- `HealthReport::CHECKS` gains `:held_tickets`; method `check_held_tickets`.
- `ActivityEvent::KINDS` and `MACHINERY_KINDS` gain `held_ticket`.
- Locale keys (both `fr` and `en`), added in step 0:
  - `web.*`: `web_admin_health_check_held_tickets`, `web_issue_close_handed_back`
    (`%{target}`), `web_issue_close_handback_failed` (`%{error}`), `web_issue_close_handback_no_target`.
  - `notifications.*`: none — the handover notice reuses `abandon_reassigned` as a suffix.

## Lanes (disjoint files; SQLite `:memory:` is per process, so each lane runs its own test files)

### Lane A — GitLab writes that never raise, and the handover handback

Files: `lib/autodev/label_manager.rb`, `lib/autodev/issue_notifier.rb`,
`app/services/autodev/external_state.rb`, `app/services/autodev/label_handover.rb`, new tests
`test/a_transport_failure_does_not_strand_a_ticket_test.rb`,
`test/a_label_handover_hands_the_ticket_back_test.rb`.

1. `manage_labels`, `hand_ticket_back`, `notify_issue`: rescue the transport family, spelled out
   like `ExternalState#notify_stop` (#115). Return values unchanged (`[]`, `false`, nil).
2. `LabelHandover#verdict` returns the suspicion with `actor_id` from the decisive event.
3. `ExternalState#stop_on_handover`: when the verdict has one, hand the ticket to
   `verdict.actor_id || issue.handback_target` (one `edit_issue`, transport family rescued and
   logged, returns whether it changed hands) **before** `notify_stop`, which gains an optional
   `suffix:` and appends `abandon_reassigned` when the ticket changed hands. `close_row!` unchanged.

### Lane B — Clore hands the ticket back

Files: `app/controllers/issues_controller.rb`, new `app/services/autodev/close_handback.rb`, new test
`test/controllers/issues_controller_close_handback_test.rb`, new `test/close_handback_test.rb`.

1. `CloseHandback#perform`: build the client (`GitlabHelpers.build_gitlab_client`), read the ticket,
   `not_held` unless an assignee id equals `GitlabHelpers.current_user_id(client)`, `no_target` when
   `issue.handback_target` is nil, else `edit_issue(assignee_ids: [target])` → `handed_back`. Any of
   the transport family, `ApiUnavailableError` or `ConfigError` → `failed` with the scrubbed message.
2. `IssuesController#close`: after `close_issue!`, run it, `Audit.record!(action:
   'issue.close_handback', payload: { project_path, iid, outcome, target_id })`, and set
   `flash[:notice]` for `handed_back`, `flash[:alert]` for `failed` / `no_target`, nothing for
   `not_held`. The close itself never depends on the outcome.

### Lane C — the held-ticket probe and its card

Files: new `app/services/autodev/held_ticket_probe.rb`, `app/services/autodev/health_report.rb`,
`app/jobs/autodev_poll_job.rb`, `app/models/activity_event.rb`, new test
`test/held_ticket_probe_test.rb`.

1. Probe: not due while the last event is younger than `INTERVAL`. Per project, one paginated
   `client.issues(path, state: 'opened', assignee_id: bot_id, per_page: 100)`; a project whose read
   fails counts in `unknown` and contributes no row. Join on `Issue.where(project_path:, issue_iid:,
   status: %w[done closed])`. Record the event even when `held` is empty (that is the good news).
2. Card: no event within `TTL` → `ok`, "no held-ticket probe on file"; `held` non-empty → `warn` with
   a sample `A#<id>(<path>#<iid>,<status>)` × 5; else `ok`, saying how many projects could not be read.
3. `AutodevPollJob#run_cycle` calls it beside the two other probes, guarded the same way.

## Step 0 (me), then lanes in parallel, then integration (me)

Integration: CHANGELOG `[Unreleased]`, CLAUDE.md (error-handling rows for the helpers, the Clore
handback, the handover handback, the card), RuboCop on the whole tree, full suite.

## Tests to write — from the plan adversary's "would stay green" list

(filled in after `ship-plan-adversary` reports)
