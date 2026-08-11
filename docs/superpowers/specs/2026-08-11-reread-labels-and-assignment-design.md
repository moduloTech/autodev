# Re-reading labels and assignment on an active row (Autodev #52)

Date: 2026-08-11
Ticket: Skynet Autodev #52 — "Autodev ne relit ni les labels ni l'assignation
d'un ticket actif : un arrêt décidé par un humain passe inaperçu"

Follows: `2026-08-07-dormant-rows-audit-design.md` (Autodev #47/#48), which
created `Autodev::ExternalState` — the one place where "what does GitLab say
about this ticket" is decided, shared by the two passes that ask.

## Problem

A human who takes a ticket back has no way of telling autodev. Autodev never
re-reads the labels.

`dispatch_unassignment` sweeps every row in `ACTIVE_STATUSES` each cycle and
calls `check_external_state`, which reads exactly two things off the GitLab
issue: `state == 'closed'` → `close_externally`, and autodev absent from
`assignees` → `stop_unassigned`. `labels` is fetched with the rest of the issue
payload on every one of those reads and thrown away.

Production, `powerpanne/core#15894`: on 24/07 at 09:23 Mario Goncalves comments
"test sur review ok", at 09:24 removes `Development::Doing` and applies
`Development::Awaiting CR`. Autodev stayed in `checking_pipeline` polling that
MR's pipeline for more than two weeks. `#16237`, `#16258` and `#16341` are the
same story.

Two smaller problems ride along:

- **`stop_unassigned` is silent on GitLab.** It writes `status: 'done'` and adds
  one line to the folded activity note (`activity_unassigned_stop`). The person
  who unassigned autodev gets no confirmation that it actually stopped — and the
  `unassigned_stop` template in `notifications.{fr,en}.yml`, which reads like the
  confirmation that was meant to be posted, has **no call site**: it is a
  leftover of the pre-Rails poller.
- **`stop_unassigned` writes `done`, not `closed`.** `done` means delivered.
  A ticket a human pulled back mid-implementation was not delivered, and #44
  already established that `closed` "says more than `done`" for the sibling case.

## Design

### 1. A stop is a `closed` row plus a GitLab comment

`ExternalState` grows one shared writer, `close_row!`, doing what
`close_externally` already did — AASM `close!`, stamp `finished_at`, clear the
`needs_attention` trio, post an activity entry — parameterised by the activity
key. `close_externally` and `stop_unassigned` both route through it, so the two
terminal outcomes can no longer drift the way the module was created to prevent.

`stop_unassigned` additionally posts a real GitLab note before closing, through
the existing (until now unused) `unassigned_stop` template, extended with the
`done_nominal`-style "put the todo label back and reassign me" hand-back line.
Notes go out through a new `ExternalState#notify_stop`, a four-line sibling of
`IssueNotifier#notify_localized`: the includers of `ExternalState`
(`PollDispatcher`, `DormantAudit`) are poll-cycle services, not
`DangerClaudeRunner` hosts, so they have `@path`/`@client`/`@logger` but none of
the `@project_path`-based mixin stack.

**What this does to `post_completion` — the side effect the ticket asks about.**
`dispatch_done_unassigned` selects `status: 'done'` + non-null `mr_iid`, checks
that autodev is no longer assigned and that the MR is neither merged nor closed,
and enqueues `:post_completion`. Today a row unassigned mid-flight lands in
exactly that set: `stop_unassigned` writes `done`, the MR is open, autodev is
gone — so the hook fires on a half-finished MR one cycle later. After this
change it lands in `closed` and the pass no longer sees it.

That is a deliberate behaviour change, not a regression, and the population the
hook actually exists for is untouched:

| how the row got to `done` + unassigned | before | after |
|---|---|---|
| `PipelineMonitor#finalize_green_done` — delivered, then `reassign_to_author` hands the ticket back | `:post_completion` | unchanged (`dispatch_unassignment` never sweeps `done`) |
| `give_up_reviewing`, `handle_stagnation`, `green_done_max_reviews` — same `reassign_to_author` | `:post_completion` | unchanged |
| `stop_unassigned` — a human unassigned autodev mid-implementation | `:post_completion` | **no longer fires** |

Every nominal completion path ends with `apply_label_done` + `reassign_to_author`
*while already in `done`*, and `dispatch_unassignment` only sweeps
`ACTIVE_STATUSES`. So the hook keeps firing for every delivery. What stops firing
is a deploy hook running over work that was interrupted on purpose — which the
docs already describe as running "sur désassignation" *après livraison*.

### 2. Detecting the label handover: scope-derived, self-disabling

"An unknown label" cannot be read literally. On `powerpanne/core` tickets
permanently carry labels outside the workflow (`PM::Evolution`, `Fourrière`,
client names, `Backlog`…); closing on that criterion would close everything.

The rule is built on **GitLab scoped labels**. A scoped label is
`key::value`, the key being everything before the *last* `::`, and GitLab
enforces at most one label per key on an issue.

**Scope derivation — one refinement over the ticket's proposal.** The ticket
proposes deriving the scope when `labels_todo` / `label_doing` / `label_done`
all share a prefix. On the only project whose labels are documented in-repo
(`docs/powerpanne-lifecycle.md`) that condition is **false**:

| setting | value | scoped? |
|---|---|---|
| `labels_todo` | `To Do` | no |
| `label_doing` | `Development::Doing` | `Development` |
| `label_done` | `Development::Awaiting Feature Review` | `Development` |

`To Do` is GitLab's stock board label and is the *entry point a human uses*; the
workflow scope is the one autodev itself lives in. So the scope is derived from
**`label_doing` and `label_done` only** — the two labels autodev owns and
writes. `labels_todo` is excluded from the derivation and merely exempted from
the verdict (re-adding the todo label on an active row is a reentry signal
handled by `PollRouter`, never a stop). With that refinement the rule is enabled
on `powerpanne/core`, which is the project the ticket was written from.

The rule, in order, applied to the `labels` array already present in the
`@client.issue` payload:

1. `label_done` is on the issue → **`done_added`**;
2. otherwise a label whose scope key equals the derived scope and which is none
   of the three configured labels → **`workflow_moved`** (this is
   `Development::Awaiting CR`, the #15894 case);
3. otherwise `label_doing` is absent → **`doing_removed`**.

Order is by informativeness, and it matters because the three overlap: applying
`Development::Awaiting CR` makes GitLab drop `Development::Doing` in the same
edit, so 2 and 3 both hold and only 2 can name where the ticket went.

**Verification of the convention across projects, and the fallback.** The
project table is not readable from here (production DB out of bounds, and the
dev copy with it), and no other project's labels are recorded in the repo. That
turns out not to be load-bearing: **the rule is self-disabling**. When
`label_doing` and `label_done` do not share a scope key — either of them
unscoped, or two different keys — `scope` is `nil`, step 2 never produces a
candidate, and what remains is exactly the fallback the ticket prescribes:
`label_doing` removed, `label_done` added. A project that does not follow the
convention degrades to the two presence rules with no false-close risk, and no
configuration or migration is needed to opt in or out.

Rejected alternatives:

- **A configured allow-list of workflow labels** (a fourth setting listing every
  label of the workflow). More precise, and dead on arrival: it is a setting
  nobody would keep in sync with the GitLab label list, and its staleness fails
  *closed* — a new workflow label nobody registered reads as "unknown" and closes
  tickets.
- **Any label not in the three configured ones → stop.** The ticket already
  rules this out; `PM::Evolution` alone would close every ticket on the project.
- **A regexp on label names.** Same maintenance problem as the allow-list,
  without the explicitness.

### 3. Attributing the edit: resource label events, read only on suspicion

Autodev applies and removes these labels itself in normal operation, so the
trigger must be "by somebody else". The ticket offers two routes.

**(a) Compare against the state machine's expectation.** While a row is in
`ACTIVE_STATUSES` autodev holds `label_doing` and has not applied `label_done`,
so *any* deviation is somebody else's. Free — zero API calls. But it is wrong at
the edges, and the edges are exactly when this fires: `apply_label_done` writes
the GitLab label a few hundred milliseconds before the row's status reaches
`done`, and `apply_label_doing` writes it before the row leaves `pending`. Those
writes happen inside an `IssueProcessJob`, serialised per ticket by
`limits_concurrency` — but the poll cycle runs in `AutodevPollJob`, *outside*
that lock. A sweep landing in the gap sees `label_done` on a `checking_pipeline`
row and closes a ticket autodev was about to deliver, with a comment blaming a
human who did nothing. That is the same class of race #50 spent a spec on.

**(b) Read the resource label events.**
`GET /projects/:id/issues/:iid/resource_label_events` (`client.issue_label_events`,
present in the `gitlab` 5.1 gem we already depend on) returns one entry per label
add/remove with `user`, `action` and `created_at`. It is what was used to
reconstruct #15894's history in the first place, and it answers the question
directly instead of inferring it.

**Chosen: (b), behind (a) used as a free pre-filter.** The two-stage shape is
what makes the cost acceptable:

- stage 1 reads the `labels` array off the issue payload `check_external_state`
  **already fetches** — zero API calls, and on a healthy ticket it produces no
  candidate, which is the overwhelmingly common case;
- stage 2 fires only when stage 1 has a candidate: one `issue_label_events` call
  for that row, that cycle. The last event naming the candidate label must have
  the action the suspicion implies (`remove` for `doing_removed`, `add` for the
  other two) and an author whose id differs from
  `GitlabHelpers.current_user_id`.

**Cost.** Nominal case: **+0 API calls** — unchanged from today's one
`@client.issue` per active row per cycle. Suspicion case: +1 call for that row,
that cycle, and the row is closed at the end of it, so it is not a recurring
cost. Compare with reading label events unconditionally, which the ticket costed
at one extra call per active row per cycle: at ~20 active rows and a 300 s
interval that is ~240 calls/hour of pure waste. The pre-filter removes all of it.

**Failing shut, on purpose.** No event, an unreadable events list, an event whose
action contradicts the suspicion, or an author id equal to autodev's → **no
stop**. A missed handover costs what the bug already costs today; a wrong stop
closes a ticket autodev is actively working on and posts a comment accusing
somebody. The asymmetry is not close. This is also what neutralises the (a) race
above: in the gap, the last event on `label_done` is autodev's own `add`.

### 4. Where the check runs

In `ExternalState`, as `stop_on_handover(issue, gl_issue)`, called from both
includers — after the closed and unassigned branches, which keep winning
(a closed or reassigned ticket is not ours whatever its labels say):

- `PollDispatcher#check_external_state` — the active sweep the ticket asks for;
- `DormantAudit#route` — inserted between "unassigned" and "revived". This is the
  #48 lesson applied: the logic that decides "not ours anymore" must not live in
  one pass while the other population is never swept. Concretely it stops the
  audit from re-arming a dormant row that a human has already moved to
  `Development::Awaiting CR`.

The detection itself lives in a new `Autodev::LabelHandover`
(`app/services/autodev/label_handover.rb`) rather than inside `ExternalState`:
scope derivation, candidate ordering and event attribution are ~60 lines with
their own vocabulary, and they are worth testing without a database.

## Testing

TDD, one test per claim.

New `test/label_handover_test.rb` — the detection, with a stub client:

- scope derivation: `Development::Doing` + `Development::Awaiting Feature Review`
  → `Development`; an unscoped `label_doing` → no scope; two different keys → no
  scope; `labels_todo` being unscoped does **not** disable it (the powerpanne
  shape, and the refinement over the ticket).
- `Development::Awaiting CR` posed by a human → `workflow_moved` naming that
  label. Posed by autodev → nothing.
- `label_done` present, added by a human → `done_added`; added by autodev
  (the delivery race) → nothing.
- `label_doing` absent, removed by a human → `doing_removed`; removed by autodev
  (the `needs_clarification` path removes it legitimately) → nothing.
- out-of-scope noise (`PM::Evolution`, `Fourrière`, `Backlog`, a client name)
  → nothing, which is the objection the ticket raises against the naive rule.
- `To Do` re-added while active → nothing (exempt, not a stop).
- with no scope derivable, `Development::Awaiting CR` → nothing, but a removed
  `label_doing` still stops: the fallback.
- an empty events list, an events list with no entry for the label, and an event
  whose action contradicts the suspicion → nothing.
- a `Gitlab::Error::ResponseError` from `issue_label_events` → nothing, no raise.
- cost: no candidate → `issue_label_events` is never called; one candidate → it
  is called exactly once.

Extended `test/external_state_test.rb`:

- `stop_unassigned` now closes instead of `done`, stamps `finished_at`, clears
  the attention trio, and posts one GitLab note.
- the note is localised and carries the hand-back label.
- `close_externally` keeps every property its existing tests pin (they must pass
  untouched — that is what proves `close_row!` is a refactor).

Extended `test/closed_on_gitlab_dispatch_test.rb` (the active sweep):

- an unassigned active row → `closed` (was `done`);
- an active row whose `Development::Doing` a human replaced with
  `Development::Awaiting CR` → `closed`, one note posted;
- the same edit made by autodev → left alone;
- a healthy row costs one `@client.issue` and **zero** `issue_label_events`.

New `test/post_completion_after_unassignment_test.rb`:

- a row unassigned mid-`checking_pipeline` is not enqueued for
  `:post_completion` afterwards (the documented change);
- a nominally-`done` unassigned row with an open MR still is (the guard against
  breaking the hook by accident).

Extended `test/dormant_audit_routing_test.rb`: unassigned dormant row → `closed`
(was `done`); a dormant row moved to another workflow label is closed rather than
re-armed.

`test/locales_test.rb`'s FR/EN parity checks cover the six new keys for free.

## Docs

- `CHANGELOG.md` `[Unreleased]`.
- `CLAUDE.md` — Error Handling table (the unassignment row, two new rows), the
  `dispatch_unassignment` bullet in the poll-pass list, the lifecycle recap under
  the schema, and a Key Design Decisions entry next to "3 labels only".
- `docs/usage/autodev-technical-usage.md` — pass 4, the réentrées/hooks list, the
  error table.
- `docs/powerpanne-lifecycle.md` — the "Désassignation" paragraph currently
  promises the ticket is marked *terminé* with `Development::Awaiting Feature
  Review`, which was never true (`stop_unassigned` writes no label); it now says
  what happens, and the new label-handover stop is described in the CSM's terms.

## Constraints

CLAUDE.md: TDD, RuboCop green (`mise x ruby -- rubocop`, never edit
`.rubocop.yml`), Conventional Commits with `(Autodev #52)`, `CHANGELOG.md`
`[Unreleased]` in the same pass, every user-facing string through `Locales.t` in
both `fr` and `en`. The FR notification/activity templates are deliberately
written **without accents** (see the existing file); the new keys follow.

## Out of scope

- Reacting to a label change on a `done`/`closed` row. Reentry from `done` is
  `PollRouter::ResumeHandler`'s job and has its own rules.
- Reopening a row when the human puts `label_doing` back. `closed` is terminal by
  design; the documented path is re-adding the todo label and reassigning, which
  `dispatch_new_issues` already handles.
- Making `post_completion` reachable from `closed`. If a project ever needs a
  hook on an interrupted ticket that is a different hook with a different name.
