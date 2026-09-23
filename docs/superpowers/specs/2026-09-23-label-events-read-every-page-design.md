# The label-events read reads every page (Autodev #116)

## Defect

`Autodev::LabelHandover#events` calls `client.issue_label_events(path, iid)` and
uses the result as the ticket's whole history. In gitlab-5.1.0 that method is a
bare `get("/projects/…/issues/…/resource_label_events")` — its signature takes
no options, so no `per_page` can be passed — and it returns a
`Gitlab::PaginatedResponse` holding **the first page only: GitLab's default of
20, the oldest 20**, since the endpoint lists events chronologically.

Every consumer wants the most recent events:

- `last_event_for` (via `decisive_event`, for `verdict` and `moved_since?`)
  takes the last event naming a label as "the edit that produced the state we
  read";
- `todo_reapplied_after?` asks whether a todo label was added after
  `finished_at`.

Past 20 events both read the wrong page, silently.

## Measurements (23/09/2026)

- **Distribution.** The 142 issues tracked in the dev DB (a copy of production,
  older than the 148 rows production held that day),
  counted through the API with `per_page=100` and full pagination: 56 have ≤ 20
  label events, **71 have 21–40, 15 have 41–100**, maximum 64. 61 % of tracked
  tickets are past the first page.
- **The live victim.** powerpanne/core#15673: `X-Total: 35`, `X-Total-Pages: 2`
  at the default page size. The todo label was reposed on 21/08/2026 10:26:54 UTC,
  after the row's `finished_at` (07:52:03 UTC), and that event is on page 2. The
  reentry gate answers false every cycle — a human request blocked for a month,
  and 720 requests/day (12.5 % of autodev's GitLab traffic, Autodev #118).
- **Reverse sort is not available** (direction 3 of the ticket): the endpoint
  ignores `sort=desc` and `order_by=created_at&sort=desc`; both answer the same
  20 oldest events as the bare call (measured 22/09/2026, ticket comment).

## Decision: `.auto_paginate` on the gem's named method (direction 1)

`events` becomes
`client.issue_label_events(path, iid).auto_paginate` — the convention the
repository already applies to paginated reads (`MrDiscussions`,
`GitlabHelpers.fetch_assignee_issues`), minus the `per_page: 100` the gem does
not let us pass.

Rejected: **a direct `client.get(…, query: { per_page: 100 })`** (direction 2).
It saves pages (reading all 142 tickets once costs 142 requests at 100 per page
against 246 at the default 20; the 86 tickets past one page account for 86
against 190), but:

1. `GitlabRequestCounter` records a request under the name of the method it
   forwards. The first page would be counted as `get` instead of
   `issue_label_events`, erasing that line from the per-endpoint breakdown
   Autodev #96 was built to produce — the very instrument the ticket asks the
   cost to be weighed against.
2. The saving applies to a population that is small: `events` is read only on a
   stage-2 candidate (a row about to be closed) and by the reentry gate, whose
   recurring population measured one row on 22/09/2026 — #15673 itself, which
   leaves that population as soon as the gate can see its event. At most
   `ceil(64 / 20) = 4` requests on the largest ticket measured.

## Consequences written down

- **Deploying this reenters #15673** on the first poll cycle: its todo label was
  genuinely reposed after the close, and the gate will now see it. That is the
  intended effect (ticket comment of 23/09/2026) and the reason Autodev #118's
  suggestion to remove that label is dropped.
- **`moved_since?` changes its answer on six handed-back rows** (adversarial
  review, simulated over the 148 production rows against the real GitLab):
  #15971, #16076, #16110, #11339, #16261, #16735 flip from "untouched" to
  "moved", and the review-arrears sweep and the infra recheck will decline them
  instead of reclaiming them. The events read on five of them are real human
  moves after the give-up (e.g. #16735, `Development::Awaiting Merge` on
  22/09/2026) — the fix protecting the people now holding them. Of the 24
  rows on which a one-page and a full read answer differently, these six and
  #15673 are the only ones a consumer acts on; the rest are `done` rows the
  reentry gate is never asked about.
- Order is still GitLab's: the full list is chronological, so `.last` in
  `last_event_for` is right once — and only once — the list is whole. The
  comments on `last_event_for`, `events`, `decisive_event`, the class header and
  `PollRouter#reenterable?` are corrected to say what is true.
- Test doubles that answer `issue_label_events` with a bare `Array` no longer
  model the gem (an `Array` has no `auto_paginate`); they return a
  `Gitlab::PaginatedResponse`, as `test/skill_reviewer_test.rb` already does.
