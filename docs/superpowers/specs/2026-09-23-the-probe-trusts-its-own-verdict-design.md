# The review-skill probe trusts its own verdict (Autodev #118)

## Problem, measured

Production, 22/09/2026 (one full UTC day, `gitlab_request_stats`): 6 060 GitLab
requests. Two endpoints are the review-skill probe:

| endpoint | requests | per cycle (720 cycles/day) |
|---|---|---|
| `read/project`  | 1 440 | 2 |
| `read/get_file` | 1 437 | 2 |

`poll_interval` is `120` in production, so `ReviewSkillProbe#ttl` is
`max(120 × 2, 600) = 600 s` — five cycles, not two. The probe nevertheless runs
on every cycle.

Both declaring projects declare a `target_branch` (`powerpanne/core` → `master`,
`ff/fast/core` → `staging`), so the `project` read — the repository default
branch — is never the answer. It is read anyway:

```ruby
def resolve(mr_iid, client:, project_path:, project_config:)
  ...
  for_new_merge_request(project_config, yield)   # yield runs before `declared || …`
end
```

The ticket attributed half the bill to not respecting the TTL. It is the other
way round: half of it is this eager `yield`, and it is a defect independent of
the probe — every caller of `TargetBranch.resolve` pays it (`Resolver` pays a
local `git symbolic-ref`, the probe pays an HTTP read). The existing test
`test_one_project_costs_one_request` stays green over it because its fake client
counts `get_file` only.

## Decisions

### 1. `TargetBranch.resolve` asks for the repository default only when nothing is declared

`for_new_merge_request(project_config, repository_default = nil)` answers
`declared(project_config) || (block_given? ? yield : repository_default)`, and
`resolve` forwards its block to it instead of calling it. The two-argument form
still works (a test uses it directly), and question 1 keeps its one definition
rather than being restated inside `resolve`. Expected effect: `read/project` → 0
for the current fleet, since both declaring projects declare a target.

### 2. The probe does not re-ask while its verdict is still trusted

`probe!` skips the GitLab reads when the last recorded verdict satisfies all of:

- **fresh at the next cycle, with half a period to spare**:
  `age + 1.5 × period < ttl`, where `period = max(poll_interval, 60)`. The half
  period absorbs the cycle's jitter (measured: ±1 s) and the probe's own
  duration, so the card never reads an expired verdict between two cycles while
  the poller runs. The 60 is because `config/recurring.yml` fires at most once a
  minute (`*/[interval / 60, 1].max`), so below 60 the real cycles are further
  apart than the setting says — a bound on the schedule, not a copy of its
  formula. At `poll_interval: 120` this re-probes every fourth cycle (age
  480 s); at the default `300` every real cycle re-probes and nothing changes.
- **healthy**: no `missing`, no `unknown`. Only good news is cached. A fault is
  re-asked every cycle, which is when an operator is watching the card and
  fixing the repository; an `unknown` (outage) is re-asked every cycle, which is
  the cadence it had before.
- **about the same fleet**: the payload records the declaring set as
  `declared: [[path, skill, declared target], …]` (sorted). Adding, removing or
  editing a project's `review_skill` or `target_branch` invalidates the verdict
  on the next cycle — the case the form's user is waiting on.

A row written before this change carries neither `unknown` nor `declared`, and
is therefore not trusted: the first cycle after deploy probes.

`probe!` returns `nil` when it skipped, `[]` when there was nothing to probe or
the probe failed, the verdicts otherwise. The only production caller
(`AutodevPollJob#probe_review_skills`) ignores the value.

### 3. No cache beyond the TTL

The ticket offers a `(project, ref)` cache as a second step. Not done: after
decisions 1 and 2 the probe costs 2 `get_file` every 4 cycles, ≈ 360
requests/day against 2 880 (÷ 8), and the remaining knob is exactly the TTL the
ticket names as the right cursor. A longer TTL means a health card that states
"present" longer after the file was deleted from the target branch; that is a
product decision about the card, not a sobriety fix, and is left to the owner.

## What still goes stale, and for how long

The file being deleted, or an undeclared target's repository default changing,
is seen at the next re-probe: one probe period after the last healthy verdict
— 480 s in production (every fourth 120 s cycle), against 120 s before. The review step itself is
unaffected — `ReviewSkillSource.locate` reads live at review time — so the
staleness is confined to the advisory card.

## Tests

The plan's list, extended by the plan adversary (`ship-plan-adversary`), which
found ten decisions the first draft of the tests would not have noticed —
among them the exact boundary (419 s trusted, 420 s re-asked), a jittered
cadence (479 s then 601 s), the one-minute floor, fleet order, a removed
project, an undeclared target, and a row carrying `declared` but no `unknown`.
See `docs/superpowers/plans/2026-09-23-the-probe-trusts-its-own-verdict.md`.
