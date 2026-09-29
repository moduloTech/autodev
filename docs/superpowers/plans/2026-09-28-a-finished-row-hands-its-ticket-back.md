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

`ship-plan-adversary` verified with in-memory mutants that each of these would pass the existing
suite if implemented wrong. Each entry is a test the lane must write.

### Lane A
- A1 (the A#134 shape): drive PipelineMonitor green → done with a client whose `issue` raises
  `Net::OpenTimeout`, then a variant where `edit_issue(labels:)` raises `Errno::ECONNRESET` —
  `hand_ticket_back` NOT stubbed, `issue_author_id: 42`: edits include `{assignee_ids: [42]}`,
  a `done_nominal` note, `finished_at` moved, a `pipeline_green_done` activity. Same shape through
  `abandon_issue`, `finalize_question`, `give_up_reviewing`.
- A1: `manage_labels` returns `[]` for each of the six `TRANSPORT_ERRORS` classes; a client
  `NoMethodError` still raises (guards against `rescue StandardError`).
- A1: `edit_issue(assignee_ids:)` raising `Net::ReadTimeout` in `abandon_issue`: row `done` +
  `needs_attention`, note posted **without** `abandon_reassigned`, `hand_ticket_back` returns exactly `false`.
- A1: `create_issue_note` raising `Errno::ECONNRESET` under `notify_localized` in
  `finalize_green_done`: `finished_at` stamped, the activity still attempted, no "Pipeline check failed" line.
- A2: two humans. `workflow_moved`: 501 removes Doing, 502 adds Awaiting CR → `actor_id == 502`.
  `doing_removed`: [bot adds Doing, 501 removes Doing, 502 adds PM::Evolution] → 501. `done_added` → the adder.
- A3: recording `edit_issue`, `issue_author_id: 42`, label event by 999 → exactly one edit
  `{assignee_ids: [999]}` — on all three paths: `ExternalState` directly,
  `PollDispatcher#dispatch_unassignment`, `DormantAudit`.
- A3: ordered call log — the `assignee_ids` edit precedes the stop note, and the note carries
  `abandon_reassigned`. `edit_issue` raising `Net::ReadTimeout`: row `closed`, note without the
  suffix, error logged, `stop_on_handover` still returns the verdict.
- A3 fallback: stubbed verdict with `actor_id: nil`, `displaced_assignee_id: 55`, author 42 → edit
  `[55]`; both nil → no edit, no suffix, row still closed.
- A3: no verdict (bot edit), and a `closed` row with a human verdict → zero `assignee_ids` edits.
- Step 0: `Issue#handback_target` model test (55/42 → 55; nil/42 → 42; nil/nil → nil), and an
  `abandon_issue` with displaced 55 edits `[55]`.
- The 10 existing handover stubs gain a **recording** `edit_issue`, not a silent no-op.

### Lane B
- `test/close_handback_test.rb`: assignees [bot] → `handed_back`, edit `[target]`; [42] →
  `not_held`, zero edits; bot + nil target → `no_target`, zero edits (never `assignee_ids: [nil]`);
  displaced 55 + author 42 → `[55]`. Reset `GitlabHelpers`' module-wide `@current_user_id` memo in
  setup and let `client.user` answer the bot id.
- `client.issue` raising `Net::OpenTimeout`, `Errno::ECONNRESET`, `ApiUnavailableError`, and
  `edit_issue` raising `Gitlab::Error::ResponseError` → each `failed`; a message carrying
  `glpat-XXXXXXXXXXXXXXXXXXXX` never reaches `Result#error` nor the flash; a client `NoMethodError` propagates.
- Controller: a stubbed `perform` records `issue.reload.status` when called → `'closed'`; for each
  stubbed outcome the row is `closed` and `finished_at` set.
- Controller: per stubbed `Result`, exactly one `AuditLog(action: 'issue.close_handback')` with
  the actor and payload `project_path` / `iid` / `outcome` (string) / `target_id`;
  `flash[:notice]` only for `handed_back`, `flash[:alert]` for `failed` / `no_target`, neither for
  `not_held`; `return_to` honoured.

### Lane C
- The stub asserts (or filters on) `state: 'opened'` and `assignee_id: <bot>`; `GitlabPagesClient`
  (`test/gitlab_pages.rb`) with two pages and the held ticket on page 2 → it is in `held`.
- Join: iid 100 on `group/a` (`done`) and iid 100 on `group/b` (`checking_pipeline`), both held →
  only `group/a`; `error` / `pending` / `needs_clarification` excluded; a GitLab issue with
  `id: 9001, iid: 100` matches on 100.
- Two projects, one raising `Net::ReadTimeout` → `unknown == 1`, the other's rows present; all
  failing → the card says they could not be read, never "0 held".
- Zero held → exactly one persisted event of `KIND`; `MACHINERY_KINDS.include?(KIND)`;
  `ActivityEvent.user_visible.where(kind: KIND)` empty.
- Due: event 14 min old → zero `issues` calls; 16 min → one per project; a 2 h and a 5 min event
  inserted in both orders → not due.
- Card: none → ok "no held-ticket probe on file"; 46 min old → same; 6 held → warn, sample of
  exactly 5 `A#<id>(<path>#<iid>,<status>)`; empty + 1 unknown → ok naming 1 unreadable project; a
  warn through `HealthReport#call` keeps `/healthz` at 200 and the card is not `:down`.
- Poll job: twins of `test/jobs/autodev_poll_job_test.rb:115,140` for `HeldTicketProbe` — called
  once with both projects and the loaded config; raising → both projects still dispatched.

Already covered (no new test): `CHECKS` order (`health_report_test.rb:259`, updated by lane C),
locale parity (`locales_test.rb:91`), `IssueNotifier#handback_target` fallbacks
(`issue_abandonment_test.rb:154,166`), a `ConfigError` handback not stopping the close
(`issues_controller_close_test.rb:23`), `verdict` nil on autodev's edit and raising on unreadable
events (`label_handover_test.rb:137,156,314,324`), `KINDS` declaration (`activity_event_test.rb:106`).
