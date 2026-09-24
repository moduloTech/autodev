# Plan — `needs_clarification` has an owner (Autodev #86)

Spec: `docs/superpowers/specs/2026-09-23-needs-clarification-has-an-owner-design.md`.
Worktree: `fix/86-needs-clarification-has-an-owner`, from `master` @ 4e81c19.
Baseline: `mise x ruby@4.0.1 -- bundle exec rake test` → 2599 runs, 0 failures.

## Frozen contract

```ruby
# app/services/autodev/clarification_watch.rb
module Autodev
  class ClarificationWatch
    include ExternalState
    # Rank order, strongest first. A flag overwrites a weaker one, never a stronger one.
    REASONS = %w[clarification_reassigned clarification_label_moved
                 clarification_budget_spent clarification_unanswered].freeze
    REACH_REASONS = %w[clarification_reassigned clarification_label_moved].freeze

    # seen_iids: Set/Array of Integer issue iids dispatch_new_issues received from
    # GitLab this cycle, or nil when that pass did not run (reach arm skipped).
    def initialize(client:, path:, config:, project_config:, logger:, seen_iids:, now: Time.current)
    def run   # → Integer, number of rows whose flag changed (set or cleared) or that were closed
  end
end

# lib/autodev/config.rb
Config::DEFAULTS['clarification_max_days'] = 14
def self.clarification_max_days(project_config, config = nil) # per project → global → DEFAULTS, .to_i

# lib/autodev/numeric_settings.rb
SPECS['clarification_max_days'] = [0, 365]
```

Activity keys (DB-only `ActivityLogger.warn_event`), fr + en in `config/locales/activity.*.yml`:
- `activity_clarification_reassigned` — no vars
- `activity_clarification_label_moved` — no vars
- `activity_clarification_budget_spent` — `%{count}`, `%{max}`
- `activity_clarification_unanswered` — `%{days}`

Web keys, fr + en in `config/locales/web.*.yml`, no vars:
`web_errors_explain_attention_clarification_{reassigned,label_moved,budget_spent,unanswered}`.

`PollDispatcher`: `dispatch_new_issues` records `@seen_iids` (a `Set` of the iids
`fetch_assignee_issues` returned, **before** `too_recent?` / routing filters); it stays `nil`
when the pass does not run. `dispatch_existing` calls `dispatch_clarification_watch` right after
`dispatch_unassignment`.

`ClarificationResume#resume!` also clears `needs_attention`, `attention_reason`, `attention_detail`.

## Lane A — server (ship-lane)

Files: `app/services/autodev/clarification_watch.rb` (new), `app/services/autodev/poll_dispatcher.rb`,
`app/services/autodev/clarification_resume.rb`, `app/services/autodev/clarification_sweep.rb`
(comment only), `lib/autodev/config.rb`, `lib/autodev/numeric_settings.rb`,
`config/locales/activity.fr.yml`, `config/locales/activity.en.yml`,
`test/i18n_derived_keys_test.rb` (declarations only), new test files under `test/`.

Tasks (TDD, each test red first):
1. `Config.clarification_max_days` + SPECS entry; range test (`0` accepted, `366` and `'quatorze'` rejected).
2. Reach arm: in `seen_iids` clears a reach flag; absent → one read; closed → `closed`; unassigned →
   `clarification_reassigned`; no todo label → `clarification_label_moved`; todo label present → nothing;
   read error → row untouched; `seen_iids: nil` → no read at all; already reach-flagged and absent → no read.
3. Budget arm and age arm, including `0` = off, NULL `clarification_requested_at`, exact-boundary day.
4. Ranking: weaker never overwrites stronger; stronger overwrites weaker; unchanged → no write, no activity row.
5. CAS: a row that left `needs_clarification` between select and write is not flagged.
6. Dispatcher wiring: `@seen_iids` recorded before `too_recent?`; the watch runs after
   `dispatch_unassignment`; not run in `dry_run` (the existing early return).
7. `resume!` clears the trio.
8. i18n: activity keys fr/en; the four reasons declared in `NO_GITLAB_COMMENT`; the column-write scan
   sees every reason (literal writes, or a declared dynamic write with its enumeration).

## Lane B — view (ship-lane)

Files: `app/components/web/views/concerns/watch_cards.rb`, `config/locales/web.fr.yml`,
`config/locales/web.en.yml`, one new test file under `test/`.

Tasks:
1. `explain_key`: `needs_clarification` + `needs_attention` → `web_errors_explain_attention_<reason>`;
   `needs_clarification` alone → `web_errors_explain_clarification` (unchanged).
2. The four web keys fr + en, plain-language, no claim that a human removed the label.

## Integration (me)

Full suite, RuboCop on the whole tree, each new test file run alone, CHANGELOG `[Unreleased]`,
CLAUDE.md (PollDispatcher passes list, Configuration defaults and bounds), render `/errors?tab=waiting`
with a flagged row.

## Plan-adversary findings (23/09/2026) — each is a test to write

Decisions added by the adversary round:

- **Foreign reason.** A `needs_clarification` row can carry a reason from another life
  (`dormant_exhausted`, reached through the CLI `--reset`, which does not clear attention). It
  ranks **below** every `clarification_*` reason: any arm that fires overwrites it; the reach-clear
  never touches it; nothing raises on `REASONS.index(nil)`.
- **`ResetReclaim` ignores `clarification_*` reasons** (`app/services/autodev/reset_reclaim.rb:45`).
  Its `needs_attention? && mr_iid` reads "autodev handed this back"; a clarification flag means the
  opposite, and without the flag the reset never reclaimed such a row. Behaviour unchanged by #86.
- **Per-row boundary** rescues `Gitlab::Error::ResponseError`, `ApiUnavailableError`,
  `StaleTransitionError` and the transport family (`SystemCallError`, `Timeout::Error`,
  `SocketError`, `OpenSSL::SSL::SSLError`, `EOFError`, spelled out as `ExternalState#notify_stop`
  does). One row's failure never stops the rest of the watch or the later passes.
- **The watch is an observation pass**: it runs when the Claude gate is closed, with
  `seen_iids: nil`, and is listed in `test/usage_gate_dispatch_test.rb`'s `OBSERVATION_PASSES`.

Tests (lane A unless marked B):

1. i18n: iterate `ClarificationWatch::REASONS`, assert `activity_%s` and
   `web_errors_explain_attention_%s` exist in fr and en; guard `NO_GITLAB_COMMENT.keys ⊆` the scanned
   attention reasons (no stale declaration). Beware `column_literal` reading a bare
   `attention_reason: reason` as the literal `"reason"`.
2. B: flagged waiting card → fr text of its explanation, no raw key, no contact line, headline
   "Question en attente" kept, not "Intervention manuelle requise"; unflagged → `web_errors_explain_clarification` text.
3. `usage_ok: false` → the watch is built with `seen_iids: nil` and a client whose `issue` raises is never called.
4. `pickup_delay: 600` + a parked row's gl_issue created 1 min ago → its iid is in the seen set (zero reads).
5. `resume!` clears the trio through `ClarificationResume` directly and through `ClarificationSweep`.
6. Budget: `retry_count == max` not flagged, `max + 1` flagged; global `max_retries: 3`, row at 2 → not flagged.
7. `Config.clarification_max_days`: `({}, {}) == 14`; project `0` over global `14` → `0`; global `5` → `5`.
8. Ranking: one row qualifying for budget and age → `clarification_budget_spent`; a
   reassigned-flagged row back in `seen_iids` with spent budget → `clarification_budget_spent` in one run.
9. Idempotence: second `run` on an already-flagged, still-qualifying row → zero `UPDATE "issues"`
   (`sql.active_record` subscription) and zero new `ActivityEvent`; include a budget/age-flagged row
   that is in `seen_iids`.
10. `run` return: three rows (flagged, unchanged-flagged, closed on GitLab) → `2`.
11. CAS during the run: `client.issue` stub moves the row to `pending` before returning an unassigned
    ticket → not flagged, no `ActivityEvent`.
12. Each reason's `ActivityEvent` exists, `level: 'warn'`, rendered text carries the numbers
    (a missing interpolation var makes `warn_event` write nothing, silently).
13. `client.issue` raising `Net::ReadTimeout` inside `dispatch_existing` → `dispatch_pipelines` and
    `dispatch_retries` still run, row untouched.
14. Closed on GitLab + row moved meanwhile (`StaleTransitionError`) → `run` does not raise, next row processed.
15. Foreign reason: `dormant_exhausted` row qualifying for budget → `clarification_budget_spent`, no raise.
16. `labels_todo: ['A', 'B']`, ticket carrying only `B`, absent from seen set → not flagged.
17. `ResetReclaim`: reset on `needs_clarification`, `mr_iid: 42`, flagged `clarification_reassigned`
    → no `update_issue`, no reclaim note.
