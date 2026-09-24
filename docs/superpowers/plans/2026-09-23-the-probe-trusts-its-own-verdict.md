# Plan — the review-skill probe trusts its own verdict (Autodev #118)

Spec: `docs/superpowers/specs/2026-09-23-the-probe-trusts-its-own-verdict-design.md`.

Single lane, implemented inline: two production files, two test files. A second
lane would split one mechanism in half.

Test invocation: `mise x ruby@4.0.1 -- bundle exec rake test` (full), or
`mise x ruby@4.0.1 -- bundle exec ruby -Itest test/<file>_test.rb` (one file).
Baseline: 2599 runs, 5301 assertions, 0 failures.

## Task 1 — `TargetBranch` resolves the repository default lazily

Files: `lib/autodev/target_branch.rb`, `test/target_branch_is_one_definition_test.rb`,
`test/review_skill_probe_test.rb`.

1. RED: in `review_skill_probe_test.rb`, the fake client counts **every**
   request (`project`, `get_file`, `commit`) in one list. Rewrite
   `test_one_project_costs_one_request` to count that list. It fails today (2).
2. RED: in `target_branch_is_one_definition_test.rb`, `resolve(nil, …)` with a
   declared target and a block that raises → must return the declared target
   without calling the block. With nothing declared → the block's value.
3. GREEN: `for_new_merge_request(project_config, repository_default = nil)`
   answers `declared(project_config) || (block_given? ? yield : repository_default)`;
   `resolve` forwards its block (`&`) instead of calling `yield` eagerly.

## Task 2 — the probe skips while a healthy verdict for the same fleet is trusted

Files: `app/services/autodev/review_skill_probe.rb`, `test/review_skill_probe_test.rb`.

Payload grows two keys: `unknown` (Integer) and `declared` (sorted
`[[path, skill, declared target]]`). `probe!` returns `nil` on a skip.

Skip iff the last event exists and
`now - created_at + 1.5 × max(interval, 60) < ttl` and `missing == []` and
`unknown == 0` and `declared == fingerprint(current declaring projects)`.

RED tests, each with a counting client and `travel_to` (the recorded row's
`created_at` has to move with the clock, which a `now:` argument would not do):

- a healthy verdict from 1 interval ago (interval 120, ttl 600) → no request;
- at `ttl − 1.5 × interval` exactly (age 420) → probes (boundary is strict);
- the prod cadence: over 12 simulated cycles at 120 s, requests happen on
  cycles 0, 4, 8 — and at every cycle `state(now:)` has a non-nil `checked_at`;
- default interval 300 → probes every cycle (no skip ever);
- a recorded `missing` → probes the next cycle;
- a recorded `unknown` → probes the next cycle;
- a project's `review_skill` changed / a project added / `target_branch`
  changed → probes;
- a legacy row with no `declared` / `unknown` keys → probes;
- a skip writes no new row (the card's `checked_at` keeps the real probe time).

## Task 3 — docs

CHANGELOG `[Unreleased]`; CLAUDE.md sentence on the probe's cadence where the
probe is described (verify against the code).

## Verification

Full suite (runs > 2599), RuboCop on the touched files and the whole tree,
sabotage of every new test, three reviews.
