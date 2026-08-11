# Re-reading labels and assignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a human stop autodev by editing a ticket's labels or unassigning it, and make the stop visible — status `closed` plus an explicit GitLab comment (Autodev #52).

**Architecture:** Two changes inside the module #48 created for exactly this kind of decision, `Autodev::ExternalState`. (1) `stop_unassigned` stops writing `done` and routes through a new shared `close_row!` alongside `close_externally`, posting a GitLab note first. (2) A new `Autodev::LabelHandover` service reads the workflow labels off the issue payload `check_external_state` already fetches, and — only when that free read produces a candidate — spends one `issue_label_events` call to check the edit was not autodev's own. Both `ExternalState` includers (`PollDispatcher#check_external_state`, `DormantAudit#route`) call it, after their closed/unassigned branches.

**Tech Stack:** Rails 8.1.3, Minitest (`test/**/*_test.rb`), plain Ruby service objects under `app/services/autodev/`, `gitlab` gem 5.1.

**Spec:** `docs/superpowers/specs/2026-08-11-reread-labels-and-assignment-design.md`

**Predecessor:** `docs/superpowers/specs/2026-08-07-dormant-rows-audit-design.md` (Autodev #47/#48) — it created `ExternalState` and the rule that both passes must reach the same conclusion.

**Worktree:** `fix/52-reread-labels-and-assignment`, branched from `master` at `83f8c71`.

## Global Constraints

- **TDD.** Failing test first, watch it fail for the right reason, then implement.
- **RuboCop must pass**: `mise x ruby -- rubocop` from the worktree root. Never edit any `.rubocop.yml`.
- **Conventional Commits**: `<type>: <description> (Autodev #52)` with a body explaining the why. End every commit message with `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- **`CHANGELOG.md` `[Unreleased]`** updated in the same pass (Task 5). It already carries entries — add to the existing section, do not create a second one.
- **Every new user-facing string goes through `Locales.t`**, with the key added to **both** `config/locales/notifications.{fr,en}.yml` and/or `activity.{fr,en}.yml`. `test/locales_test.rb` enforces FR/EN parity, so a one-sided key fails the suite.
- **FR templates are written without accents.** Look at `notifications.fr.yml` (`desassigne`, `creee`, `echec`): that is deliberate and the new keys follow it.
- **Language per document.** `CHANGELOG.md`, `CLAUDE.md` and everything under `docs/superpowers/` are English. `docs/usage/autodev-technical-usage.md` and `docs/powerpanne-lifecycle.md` are **French** — do not switch them.
- **Never call the real GitLab API.** All tests use stub clients; no comment is ever posted on a real ticket.
- **Baseline:** `1350 runs, 2608 assertions, 0 failures, 0 errors` on `master`. The final suite must be green with strictly more runs.
- **Test commands** (worktree root):
  - one file: `mise x ruby -- bundle exec rake test TEST=test/<name>_test.rb`
  - full suite: `mise x ruby -- bundle exec rake test`

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `app/services/autodev/label_handover.rb` | **New.** Scope derivation, candidate ordering, author attribution | 1 |
| `test/label_handover_test.rb` | **New.** The detection rule, DB-free | 1 |
| `config/locales/notifications.{fr,en}.yml` | `unassigned_stop` reworked + 3 `handover_*` keys | 2 |
| `config/locales/activity.{fr,en}.yml` | 3 `activity_handover_*` keys | 2 |
| `app/services/autodev/external_state.rb` | `close_row!`, `notify_stop`, `stop_unassigned` → closed, `stop_on_handover` | 2, 3 |
| `test/external_state_test.rb` | Extended: the writers | 2, 3 |
| `app/services/autodev/poll_dispatcher.rb` | `check_external_state` gains the handover branch | 3 |
| `app/services/autodev/dormant_audit.rb` | `route` gains the handover branch | 3 |
| `test/closed_on_gitlab_dispatch_test.rb` | Extended: the active sweep end-to-end | 3 |
| `test/dormant_audit_routing_test.rb` | Extended: `closed` instead of `done`, handover branch | 3 |
| `test/post_completion_after_unassignment_test.rb` | **New.** The documented `post_completion` change | 4 |
| `CHANGELOG.md`, `CLAUDE.md`, `docs/usage/autodev-technical-usage.md`, `docs/powerpanne-lifecycle.md` | Docs | 5 |

---

### Task 1: `Autodev::LabelHandover` — did somebody else move this ticket?

**Files:**
- Create: `app/services/autodev/label_handover.rb`
- Create: `test/label_handover_test.rb`

**Interfaces:**
- Consumes: `GitlabHelpers.field`, `GitlabHelpers.current_user_id(client)`, `client.issue_label_events(path, iid)` (gitlab gem 5.1, `Gitlab::Client::ResourceLabelEvents`).
- Produces: `#verdict(gl_issue, issue_iid)` → `Verdict(reason, label)` or `nil`. `reason` ∈ `:done_added | :workflow_moved | :doing_removed`; `label` is the GitLab label name that carries the meaning. Task 3 turns `reason` into the locale key suffix, so the three symbols are part of the contract.

**Context:**
- A GitLab scoped label is `key::value`; the key is everything before the **last** `::` (`A::B::C` has key `A::B`). Use `rpartition('::')` and treat an empty separator as "unscoped".
- The scope is derived from `label_doing` + `label_done` **only** — see spec §2. On `powerpanne/core`, `labels_todo` is `To Do` (unscoped) while the two others are `Development::…`; deriving from all three would disable the rule on the very project the ticket comes from.
- A resource label event looks like `{ id:, user: { id:, username: }, created_at:, action: 'add'|'remove', label: { id:, name:, … } }`. `label` can be `null` when the label has since been deleted — `GitlabHelpers.field(nil, :name)` already returns `nil`, so no extra guard is needed, but do not call `.name` directly.
- Events come back in chronological order; take the **last** one naming the candidate label.
- Fail shut everywhere: no events, no matching event, contradicting action, author is autodev, or a `Gitlab::Error::ResponseError` → return `nil`. A false stop closes a live ticket and blames a human.

- [ ] **Step 1: Write `test/label_handover_test.rb`**

Shape it on `test/external_state_test.rb`: plain `Minitest::Test`, no `DatabaseTestHelper` (this class never touches the DB), `GitlabHelpers.instance_variable_set(:@current_user_id, AUTODEV_ID)` in `setup` because `current_user_id` memoizes globally.

Stub client:

```ruby
AUTODEV_ID = 7
HUMAN_ID = 999

FakeUser = Struct.new(:id)
FakeLabel = Struct.new(:name)
FakeEvent = Struct.new(:action, :label, :user)
FakeIssue = Struct.new(:labels)

class StubClient
  attr_reader :event_calls

  def initialize(events: [])
    @events = events
    @event_calls = 0
  end

  def user = FakeUser.new(AUTODEV_ID)

  def issue_label_events(_project, _iid)
    @event_calls += 1
    @events
  end
end
```

Helpers: `POWERPANNE = { 'labels_todo' => ['To Do'], 'label_doing' => 'Development::Doing', 'label_done' => 'Development::Awaiting Feature Review' }`, plus `def ev(action, name, user_id) = FakeEvent.new(action, FakeLabel.new(name), FakeUser.new(user_id))` and a `verdict(labels:, events:, config: POWERPANNE)` wrapper.

Cases (one assertion each, named after the claim):

1. `test_a_workflow_label_posed_by_a_human_stops_the_row` — labels `['To Do'… no]`: use `['Development::Awaiting CR', 'PM::Evolution']`, events `[ev('add', 'Development::Doing', AUTODEV_ID), ev('remove', 'Development::Doing', HUMAN_ID), ev('add', 'Development::Awaiting CR', HUMAN_ID)]` → reason `:workflow_moved`, label `'Development::Awaiting CR'`. **This is #15894.**
2. `test_the_same_move_made_by_autodev_is_not_a_stop` — same labels, the `add` authored by `AUTODEV_ID` → `nil`.
3. `test_the_done_label_posed_by_a_human_stops_the_row` — labels `['Development::Awaiting Feature Review']`, matching `add` by human → `:done_added`.
4. `test_the_done_label_applied_by_autodev_is_the_delivery_race_not_a_stop` — same labels, `add` by `AUTODEV_ID` → `nil`. Reference the race in the comment: `apply_label_done` writes the label just before the row reaches `done`.
5. `test_doing_removed_by_a_human_stops_the_row` — labels `['PM::Evolution']`, events `[ev('remove', 'Development::Doing', HUMAN_ID)]` → `:doing_removed`.
6. `test_doing_removed_by_autodev_is_not_a_stop` — same with `AUTODEV_ID` → `nil`. Comment: the `needs_clarification` path removes `label_doing` legitimately.
7. `test_labels_outside_the_workflow_scope_are_ignored` — labels `['Development::Doing', 'PM::Evolution', 'Fourriere', 'Backlog', 'Client Machin']`, no events → `nil`. This is the objection the ticket raises against the naive rule.
8. `test_re_adding_the_todo_label_is_not_a_stop` — labels `['Development::Doing', 'To Do']` → `nil`.
9. `test_the_scope_comes_from_the_two_labels_autodev_owns` — same as 1 but with `'labels_todo' => ['To Do']` asserted to be irrelevant: the verdict is still `:workflow_moved`. (Covered by 1; make it explicit with a config whose `labels_todo` is a scoped label from another scope, e.g. `['Board::ToDo']`, and assert `:workflow_moved` still fires.)
10. `test_without_a_shared_scope_a_foreign_label_is_ignored` — config `{'labels_todo' => ['To Do'], 'label_doing' => 'In Progress', 'label_done' => 'Development::Awaiting Feature Review'}`, labels `['In Progress', 'Development::Awaiting CR']` → `nil`.
11. `test_without_a_shared_scope_a_removed_doing_label_still_stops` — same config, labels `['Development::Awaiting CR']`, events `[ev('remove', 'In Progress', HUMAN_ID)]` → `:doing_removed`. **The fallback.**
12. `test_an_empty_event_list_does_not_stop` / `test_an_event_for_another_label_does_not_stop` / `test_a_contradicting_action_does_not_stop` (labels say `label_doing` is gone but the last event on it is an `add`) → `nil`.
13. `test_a_gitlab_error_does_not_stop` — client whose `issue_label_events` raises `Gitlab::Error::ResponseError` (build it the way `closed_on_gitlab_dispatch_test.rb` does, with `FakeResponse`/`FakeRequest` structs) → `nil`, nothing raised.
14. `test_a_healthy_ticket_costs_no_extra_api_call` — labels `['Development::Doing', 'PM::Evolution']` → `nil` **and** `client.event_calls == 0`. This is the cost claim of the design; without it the two-stage shape can silently collapse into an unconditional call.
15. `test_a_candidate_costs_exactly_one_api_call` — case 1's input → `client.event_calls == 1`.
16. `test_no_label_workflow_configured_is_a_no_op` — config `{}` → `nil`, zero calls.

Run: `mise x ruby -- bundle exec rake test TEST=test/label_handover_test.rb`. Expect `NameError: uninitialized constant Autodev::LabelHandover`.

- [ ] **Step 2: Implement `app/services/autodev/label_handover.rb`**

```ruby
# frozen_string_literal: true

module Autodev
  # Did somebody other than autodev move this ticket on with its labels?
  # ...
  class LabelHandover
    Verdict = Struct.new(:reason, :label)

    SCOPE_SEPARATOR = '::'

    # The resource-label-event action each suspicion implies. An event carrying
    # the other one means the labels we read are stale, not that a human acted.
    EXPECTED_ACTION = { done_added: 'add', workflow_moved: 'add', doing_removed: 'remove' }.freeze

    def initialize(client:, path:, project_config:, logger:)
      # ...
    end

    def verdict(gl_issue, issue_iid)
      suspicion = suspect(Array(::GitlabHelpers.field(gl_issue, :labels)))
      return unless suspicion
      return unless by_someone_else?(issue_iid, suspicion)

      suspicion
    end
    # private: suspect / foreign_scoped / scope / scope_of / by_someone_else? / last_event_for
  end
end
```

Ordering inside `suspect` is `done_added` → `workflow_moved` → `doing_removed`; the spec explains why (a scoped move drops `label_doing` in the same edit, so 2 and 3 both hold and only 2 names the destination).

Keep the class under RuboCop's `Metrics/ClassLength` and each method under `Metrics/AbcSize` — the natural decomposition above already does.

Run the file's tests: all green. Run `mise x ruby -- rubocop app/services/autodev/label_handover.rb test/label_handover_test.rb`.

- [ ] **Step 3: Commit** — `feat: read the workflow labels to detect a human handover (Autodev #52)`

---

### Task 2: A stop is a `closed` row plus a GitLab comment

**Files:**
- Modify: `config/locales/notifications.fr.yml`, `notifications.en.yml`, `activity.fr.yml`, `activity.en.yml`
- Modify: `app/services/autodev/external_state.rb`
- Modify: `test/external_state_test.rb`

**Interfaces:**
- Produces: `ExternalState#close_row!(issue, activity_key, **vars)` (shared writer), `#notify_stop(issue, key, **vars)` (GitLab note), and `#stop_unassigned` rewritten on top of both. Task 3 reuses all three.
- The includer contract grows: it must now also expose `@project_config` (for `labels_todo`). `PollDispatcher` and `DormantAudit` both already have it; update the module's leading comment.

**Context:**
- `notifications.{fr,en}.yml` **already contains** an `unassigned_stop` key with **no call site** — a leftover of the pre-Rails poller. Rework it (add the `done_nominal`-style hand-back line) and finally use it; do not add a second key.
- `ActivityLogger.post(ctx, issue, key, **vars)` looks the key up as `activity_#{key}`, so passing `:unassigned_stop` reads `activity_unassigned_stop` (exists) and `:handover_workflow_moved` reads `activity_handover_workflow_moved` (to add).
- `ActivityLogger.tag` is the `"**autodev** (vX)"` string every notification interpolates as `%{tag}`.
- `Locales.t` raises `I18n::MissingInterpolationArgument` on a missing `%{var}`, so every template's vars must always be passed. `label_todo` may legitimately be `nil` when a project configures no `labels_todo` — that is the pre-existing behaviour of `done_nominal`, do not add a branch for it.

- [ ] **Step 1: Locale keys**

`notifications.fr.yml` — rework `unassigned_stop`, add three:

```yaml
  unassigned_stop: |-
    :stop_sign: %{tag} : j'ai ete desassigne de ce ticket, j'arrete le travail en cours.

    :arrow_right: **Vous souhaitez que je reprenne ?** Remettez le label _%{label_todo}_ et reassignez-moi.
  handover_doing_removed: |-
    :stop_sign: %{tag} : le label _%{label}_ a ete retire par quelqu'un d'autre, j'arrete le travail en cours.

    :arrow_right: **C'etait une erreur ?** Remettez le label _%{label_todo}_ et reassignez-moi.
  handover_done_added: |-
    :stop_sign: %{tag} : le label _%{label}_ a ete pose par quelqu'un d'autre, j'arrete le travail en cours.

    :arrow_right: **C'etait une erreur ?** Remettez le label _%{label_todo}_ et reassignez-moi.
  handover_workflow_moved: |-
    :stop_sign: %{tag} : ce ticket est passe au label _%{label}_, j'arrete le travail en cours.

    :arrow_right: **C'etait une erreur ?** Remettez le label _%{label_todo}_ et reassignez-moi.
```

`notifications.en.yml` — the same four, in English. `activity.{fr,en}.yml` — three one-liners:
`activity_handover_doing_removed`, `activity_handover_done_added`, `activity_handover_workflow_moved`, each interpolating `%{label}` (e.g. FR `":stop_sign: Label _%{label}_ retire par un tiers, travail en cours arrete"`).

- [ ] **Step 2: Write the failing tests in `test/external_state_test.rb`**

The existing `Host` needs `@project_config` and the `StubClient` needs `create_issue_note` (returning a `Struct.new(:id)`) plus a `notes` accumulator. Then:

- `test_stopping_an_unassigned_row_closes_it` — replaces `test_stopping_an_unassigned_row_moves_it_to_done`; assert `'closed'`.
- `test_stopping_an_unassigned_row_stamps_finished_at`.
- `test_stopping_an_unassigned_row_clears_the_attention_flags` — the row may have been flagged `dormant_exhausted`; a ticket a human took back should stop shouting.
- `test_stopping_an_unassigned_row_posts_one_gitlab_note` — `notes.size == 1` and the body mentions the hand-back label.
- `test_stopping_an_already_closed_row_is_a_no_op` — no second note, no raise.
- The five existing `close_externally` tests must pass **untouched** — that is what proves `close_row!` is a refactor and not a rewrite.

Watch them fail.

- [ ] **Step 3: Implement in `external_state.rb`**

```ruby
def stop_unassigned(issue)
  return unless issue.may_close?

  @logger.info("Issue ##{issue.issue_iid}: no longer assigned, stopping and closing", project: @path)
  notify_stop(issue, :unassigned_stop)
  close_row!(issue, :unassigned_stop)
end

# The one terminal write. `close_externally` and `stop_unassigned` differ only
# by the activity entry they leave behind — #48 exists because two passes
# disagreed about this decision, so the write itself lives in one place.
def close_row!(issue, activity_key, **vars)
  issue.close!
  ::Issue.where(id: issue.id).update_all(finished_at: Time.current, needs_attention: false,
                                         attention_reason: nil, attention_detail: nil)
  ::ActivityLogger.post(::ActivityLogger::Ctx.new(@client, @path, @logger), issue, activity_key, **vars)
end

# The activity log alone was not enough (#52): it is one line appended to a
# folded note nobody re-reads. A stop decided by a human deserves an answer on
# the thread. Sibling of IssueNotifier#notify_localized, which this layer
# cannot use — these are poll-cycle services, not DangerClaudeRunner hosts.
def notify_stop(issue, key, **vars)
  message = ::Locales.t(key, locale: (issue.locale || 'fr').to_sym,
                        tag: ::ActivityLogger.tag, label_todo: first_labels_todo, **vars)
  @client.create_issue_note(@path, issue.issue_iid, message)
rescue ::Gitlab::Error::ResponseError => e
  @logger.error("Failed to post the stop notice on ##{issue.issue_iid}: #{e.message}", project: @path)
end

def first_labels_todo = Array((@project_config || {})['labels_todo']).first
```

`close_externally` keeps its `may_close?` guard and its log line, and delegates its body to `close_row!(issue, :closed_externally)`.

- [ ] **Step 4: Commit** — `fix: close and announce a ticket autodev was unassigned from (Autodev #52)`

---

### Task 3: Wire the handover into both passes

**Files:**
- Modify: `app/services/autodev/external_state.rb` (add `stop_on_handover`)
- Modify: `app/services/autodev/poll_dispatcher.rb` (`check_external_state`)
- Modify: `app/services/autodev/dormant_audit.rb` (`route`)
- Modify: `test/closed_on_gitlab_dispatch_test.rb`, `test/dormant_audit_routing_test.rb`

**Interfaces:**
- `ExternalState#stop_on_handover(issue, gl_issue)` → `true` when it closed the row, `false` otherwise. `DormantAudit#route` branches on the boolean (a handover must not fall through to `revive`).

**Context:**
- Ordering is fixed and load-bearing: closed > unassigned > handover > (revive). A closed or reassigned ticket is not ours whatever its labels say.
- Both test files' `FakeIssue` is `Struct.new(:state, :assignees)` — it needs a `labels` member. `GitlabHelpers.field` returns `nil` for a missing member on a Struct-with-labels, and `Array(nil)` is `[]`, so tests that do not care can keep passing `nil`.
- Both `StubClient`s need `issue_label_events` (default `[]`) and `create_issue_note`.

- [ ] **Step 1: Failing tests**

`test/closed_on_gitlab_dispatch_test.rb` (rename the file's leading comment to mention #52 alongside #44):
- `test_an_open_unassigned_ticket_is_now_closed` — replaces `…_still_goes_to_done`.
- `test_a_ticket_moved_to_another_workflow_label_is_closed` — labels `['Development::Awaiting CR']`, a human `add` event → `'closed'`, one note posted.
- `test_the_same_move_made_by_autodev_leaves_the_row_alone` — still `'checking_pipeline'`.
- `test_a_healthy_row_costs_one_issue_read_and_no_label_event_read` — the cost pin.
- The existing closure tests keep passing untouched.

`test/dormant_audit_routing_test.rb`:
- `test_an_unassigned_pending_row_is_closed` — replaces `…_goes_to_done`.
- `test_a_row_moved_to_another_workflow_label_is_closed_not_rearmed` — the orphan `pending` row carrying `Development::Awaiting CR` must not be re-armed. Assert `'closed'` **and** `next_retry_at` still nil.
- `test_a_row_still_ours_is_still_revived` — the existing revive tests must keep passing; give the fixture `Development::Doing` so it is not read as a handover.

Note: `PROJECT_CONFIG` in both files must gain the three label keys.

- [ ] **Step 2: Implement**

`external_state.rb`:

```ruby
# Autodev is still the assignee and the ticket is still open — but did somebody
# move it on with the labels? Returns true when that closed the row.
def stop_on_handover(issue, gl_issue)
  return false unless issue.may_close?

  verdict = LabelHandover.new(client: @client, path: @path, project_config: @project_config,
                              logger: @logger).verdict(gl_issue, issue.issue_iid)
  return false unless verdict

  key = :"handover_#{verdict.reason}"
  @logger.info("Issue ##{issue.issue_iid}: #{verdict.reason} (#{verdict.label}), stopping and closing",
               project: @path)
  notify_stop(issue, key, label: verdict.label)
  close_row!(issue, key, label: verdict.label)
  true
end
```

`poll_dispatcher.rb#check_external_state`: replace the trailing `stop_unassigned(issue)` line with an early `return stop_unassigned(issue) unless assigned_to_autodev?(gl_issue)` followed by `stop_on_handover(issue, gl_issue)`.

`dormant_audit.rb#route`: insert `elsif stop_on_handover(issue, gl_issue)` with its own `log_outcome(issue, attempt, 'handed over via labels')` between the unassigned branch and the revive branch. If RuboCop flags `Metrics/MethodLength` or `Metrics/AbcSize`, extract the outcome table rather than disabling the cop.

- [ ] **Step 3: Commit** — `feat: stop on a label handover in both external-state passes (Autodev #52)`

---

### Task 4: Pin what happens to `post_completion`

**Files:**
- Create: `test/post_completion_after_unassignment_test.rb`

**Context:** the change is intentional (spec §1) but invisible unless a test states it. Model the file on `test/infra_recheck_dispatch_test.rb` for the enqueue assertions (it stubs `IssueProcessJob.perform_later` by capturing enqueued jobs).

- [ ] **Step 1: Write the tests**

- `test_a_row_stopped_mid_flight_is_not_sent_to_post_completion` — run `dispatch_unassignment` on an unassigned `checking_pipeline` row with an MR, then `dispatch_done_unassigned` with `post_completion` configured; assert nothing enqueued and the row is `closed`.
- `test_a_delivered_row_still_reaches_post_completion` — a `done` + unassigned row with an open MR is enqueued as `:post_completion`. This is the guard: it is the population the hook exists for, and it must survive.

- [ ] **Step 2: Commit** — `test: pin post-completion's population after the unassignment change (Autodev #52)`

---

### Task 5: Docs

**Files:** `CHANGELOG.md`, `CLAUDE.md`, `docs/usage/autodev-technical-usage.md`, `docs/powerpanne-lifecycle.md`

- [ ] **Step 1: `CHANGELOG.md` `[Unreleased]`** — one entry per behaviour, in the house style (long, causal, naming the production tickets #15894 / #16237 / #16258 / #16341): the label re-read with the scope rule and its self-disabling fallback; the two-stage attribution and its zero nominal API cost; `stop_unassigned` → `closed` + GitLab note, **including the `post_completion` consequence stated plainly**.

- [ ] **Step 2: `CLAUDE.md`**
- Error Handling table: rewrite `Unassigned during implementation`; add `Workflow label removed / changed by a human` and `label_done applied by a human`.
- `PollDispatcher + IssueProcessJob`: the `dispatch_unassignment` bullet now says "closed on GitLab, unassigned, or handed over via labels → `closed` inline".
- The lifecycle recap under the schema: `done + unassigned at poll → running_post_completion` stays (it describes the delivered population); add the `active + unassigned/handover at poll → closed` line.
- Key Design Decisions: an entry after "3 labels only" describing the scope-derived handover rule and why attribution is read from resource label events.

- [ ] **Step 3: `docs/usage/autodev-technical-usage.md`** (French) — pass 4 in the polling list, the `Réentrées et hooks` list, and the error table row `Désassigné en cours d'implémentation`.

- [ ] **Step 4: `docs/powerpanne-lifecycle.md`** (French) — the *Désassignation* paragraph claims the ticket is marked *terminé* with `Development::Awaiting Feature Review`; `stop_unassigned` never wrote a label, and it now closes the row instead. Rewrite it, and add the label handover to the CSM-facing list of ways to stop autodev.

- [ ] **Step 5: Full verification** — `mise x ruby -- bundle exec rake test` (green, > 1350 runs) and `mise x ruby -- rubocop` (green). Paste both outputs into the final report.

- [ ] **Step 6: Commit** — `docs: record the label handover and the unassignment closure (Autodev #52)`

## Open questions for a human

- `post_completion` no longer fires for a ticket a human took back mid-flight. The design assumes that hook is a delivery hook. If any project uses "unassign autodev" as a manual trigger for it on unfinished work, that flow breaks and needs its own action.
- Only `powerpanne/core`'s labels are documented in the repo. The rule self-disables for a project whose `label_doing`/`label_done` do not share a scope, so nothing breaks — but such a project gets the two presence rules only, and nobody is told.
