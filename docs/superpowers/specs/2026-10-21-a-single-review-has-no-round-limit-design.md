# A single review has no round limit (Autodev #78)

## The finding

`PipelineMonitor#green_branch` routed a green pipeline on `review_count`:
`>= Reviewer::MAX_REVIEW_ROUNDS` (3) → `:review_limit` → `green_done_max_reviews`
→ `abandon_issue(:review_limit_reached)`; `0` → `:first_review`; otherwise
`:post_review`.

`review_count` cannot reach 3. Its writers, read on the base `82cf6b1`:

| Writer | Value written |
|---|---|
| `Reviewer#increment_review_count` (`reviewer.rb:482`), called once, from `finalize_review_success`, reached only from `reviewing`, which `green_first_review` enters only at `review_count == 0` | `0 → 1`, once |
| `ResumeHandler#reenter_via_pipeline_check` (`reentry_review_count`) | `min(count, 1)` |
| `ResumeHandler#reenter_via_reimplementation` | `0` |

The dashboard reset, `Issue::MANUAL_REENTRY_BUDGETS` and
`autodev:recheck_review_arrears` never write it above 1 (batch recon, re-read).
The `:review_limit` branch and the `review_limit_reached` give-up were reachable
only in tests that forced `review_count: 3` by hand.

Measured, read-only, on 2026-10-21:

| Database | `review_count` distribution | rows with `attention_reason = 'review_limit_reached'` | `activity_events` rows mentioning `review_limit` |
|---|---|---|---|
| production (`bobette-autodev`) | `0` → 65, `1` → 102, `> 1` → 0 | 0 | 0 |
| development copy (`~/.autodev/autodev.db`, events up to 2026-08-12) | `0` → 82, `1` → 60 | 0 | 0 |

The review running exactly once per merge request is not a defect: PowerPanne's
review skill requires it ("The adversarial pass runs once per MR — never re-run it
on the fixed commit … the loop never converges"). What bounds the correction loop
is discussion stagnation (`stagnation_threshold` rounds of the same unresolved
set → `stagnation_discussions`), with the `fix_rounds_exhausted` ceiling above it
(`stagnation_threshold * 3` on `discussion_fix_round`).

## Decision (owner, option 1 of the ticket)

Delete the dead path rather than keep it as a defensive net:

- `Reviewer::MAX_REVIEW_ROUNDS`, the `:review_limit` branch of `green_branch` and
  `dispatch_green`, and `green_done_max_reviews`. The green routing becomes:
  `review_count` zero → first review, anything else → post review.
- The `review_limit_reached` attention reason: its three sinks
  (`notifications.{fr,en}.yml` `review_limit_reached`, `activity.{fr,en}.yml`
  `activity_review_limit_reached`, `web.{fr,en}.yml`
  `web_errors_explain_attention_review_limit_reached`).
- The tests that forced `review_count: 3` to reach it. Those that pinned something
  still true — the abandon machinery, reason-specific routing, the infra recheck
  and arrears sweep populations — are rewritten around a live reason
  (`fix_rounds_exhausted`, `mr_closed_unmerged`) instead of being dropped.

### Is a locale key still rendered for an existing row?

`Web::Views::Concerns::WatchCards#explain_key` builds
`web_errors_explain_attention_<reason>` from the row's `attention_reason`, and
the timeline renders the activity line. A row or event still carrying
`review_limit_reached` would render the bare key after the deletion. Production
and the development copy carry none (table above), and nothing can write one any
more, so deleting the keys renders nothing raw.

### What a value above 1 does now

Nothing distinct: it routes to post review like 1. No writer produces one; a
hand-written database value would take the ordinary post-review path (deliver if
no thread is open, fix otherwise), which is what a reviewed request does.

### The reentry cap stays

`ResumeHandler#reentry_review_count` still caps at 1 (`[count, 1].min`). Its only
stated reason was the `:review_limit` short-circuit, which is gone; what it buys
now is that `review_count` keeps the `{0, 1}` domain every reader assumes
(`resume_handler.rb`'s "reviewed?" wording, `ReviewArrearsSweep`'s
`review_count: 0`). Its comment is rewritten to say so. *Owner may reverse* —
see below.

### A guard for the leftover, not for the original defect

`test/i18n_derived_keys_test.rb` checks that every reason the code writes has its
three keys. Nothing checked the reverse: a `web_errors_explain_attention_<reason>`
in the tables for a reason nothing writes any more — which is what this deletion
leaves behind if one key is forgotten. A test is added deriving it from the same
vocabulary (`attention_reasons`). It does **not** detect a reason whose writer
exists but is unreachable, which was this ticket's shape; that would need a
reachability analysis no test here performs.

## Out of scope

- Re-running the review after each correction round (option 3): the project's
  doctrine says the loop does not converge.
- Any change to stagnation detection or to the `fix_rounds_exhausted` ceiling.

## Owner may reverse

- **Keeping the reentry cap at 1.** Options: (a) keep `[count, 1].min` (chosen);
  (b) drop the cap and keep the inherited value. On the motivating case (no row
  above 1 exists, none can be produced) both behave identically; (a) keeps a
  hand-edited value above 1 from surviving a reentry, (b) removes three lines and
  two tests whose reason has disappeared.
