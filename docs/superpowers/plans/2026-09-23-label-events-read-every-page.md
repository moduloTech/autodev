# Plan — the label-events read reads every page (Autodev #116)

Spec: `docs/superpowers/specs/2026-09-23-label-events-read-every-page-design.md`.

## Production change (one file)

`app/services/autodev/label_handover.rb`

1. `events(issue_iid)` — `@client.issue_label_events(@path, issue_iid).auto_paginate`
   inside the existing `GitlabHelpers.answer(:issue_label_events)` block (so a
   transport failure on page 2..N raises `ApiUnavailableError` exactly like one
   on page 1 — the block now covers every page turn). Drop the `Array(...)`
   wrapper: `auto_paginate` already answers an Array.
2. Comments made true: class header ("that read costs an API call" → one per
   page of 20), `decisive_event` ("one API call"), `last_event_for` (the order
   holds on the whole list, which is why it has to be whole), `events` (the
   "self-correcting" sentence is only true of an outage; this defect was the
   counter-example).

`lib/autodev/poll_router.rb` — `reenterable?` comment: "one call per cycle" →
one call per page; the 12/08 "zero rows" measurement superseded by the
22/09 one (one row, #15673, whose recurring cost was this defect, not the
dashboard-close case the comment names).

`CLAUDE.md` — the "`closed` is almost terminal" paragraph carries the same
cost sentence and the same 12/08 measurement; corrected alongside.

`CHANGELOG.md` — `[Unreleased]` / Fixed.

## Test doubles

Every fake that answers `issue_label_events` with a bare Array stops modelling
the gem (Array has no `auto_paginate` → `NoMethodError`, which is not in
`TRANSPORT_ERRORS` and so travels as itself). They return
`Gitlab::PaginatedResponse.new(array)` instead. Files: `label_handover_test`,
`poll_router_reenter_test`, `errored_retry_respects_a_handover_test`,
`infra_recheck_dispatch_test`, `external_state_test`, `dormant_audit_routing_test`,
`closed_on_gitlab_dispatch_test`, `post_completion_after_unassignment_test`,
`services/autodev/review_arrears_sweep_test`.

## New tests — `test/label_events_read_every_page_test.rb`

Two-page histories built from the **real** `Gitlab::PaginatedResponse`: page 1
carries a `link: <…?page=2>; rel="next"` header, and the fake client's `get`
serves page 2 — so the gem's own `auto_paginate` / `next_page` /
`client_relative_path` run, not a stand-in.

- T1 `todo_reapplied_after?` true when the only todo add after `finished_at` is
  on page 2 (the #15673 shape: page 1 ends on a todo *remove* before the
  threshold).
- T2 `verdict` — page 1 ends with a human add of a foreign workflow label,
  page 2 has autodev's later add of the same label → nil (no false close).
- T3 `verdict` — page 1 ends with autodev's add, page 2 has a human's later add
  → a Verdict (no missed handover).
- T4 a transport error raised while fetching page 2 → `ApiUnavailableError`
  (never a verdict computed on page 1 alone).
- T5 `PollRouter` wiring: a `closed` row whose todo add is on page 2 reenters.
- T6 the #96 counter names the first page `issue_label_events` and the second `get`.

Added after the plan adversary (every fixture above has exactly two pages, so a
read capped at two pages — or at forty events — would pass them all):

- T7 a three-page history, deciding event on page 3, for `todo_reapplied_after?`,
  `verdict` and `moved_since?`, asserting `fetched == [1, 2, 3]`.
- T8 `moved_since?` (the `UntouchedSinceGiveup` question) with the human edit on page 2.
- T9 the page-2 transport failure through `verdict` too, not only the reentry gate.
- T10 the page-2 failure behind `GitlabRequestCounter`, the client production holds:
  recorded as a `get` transport failure, and still `ApiUnavailableError`.
- `label_handover_test`'s `test_a_candidate_costs_exactly_one_api_call` renamed:
  it counts calls to the named method, which is 1 whatever the page count.

## Verification

`mise x ruby@4.0.1 -- bundle exec rake test` (baseline 2599 runs, 0 failures),
each new/touched test file run alone, `mise x ruby@4.0.1 -- bundle exec rubocop`
on the touched files, sabotage of every new test.
