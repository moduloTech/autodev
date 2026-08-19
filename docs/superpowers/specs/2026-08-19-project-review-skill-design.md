# The review step runs the project's own review skill (Autodev #74, re-scoped)

PowerPanne and Fast each ship a review skill in `.claude/skills/`, encoding that
project's review process: its conventions checklist, its severity scale, its
verify-before-you-flag discipline, its adversarial pass. Autodev clones the repo
before it reviews, so those skills are already sitting in the work directory —
and it ignores them, shelling out to the `mr-review` binary instead.

This spec makes the review step **use the project's skill when the project
declares one**, and keeps the `mr-review` binary for every project that does
not. The binary path is not deprecated; it stays the right answer where no
project skill exists.

## Problem

Three things are wrong today, and they compound.

**The project's review process is unused.** `mr-review` applies a generic
review. The skills apply the project's: Fast's checks structured logging, `nil`
over `""`, RSwag for API v2, tenant scoping; PowerPanne's runs a mandatory
adversarial pass in a fresh subagent and forbids classifying a concern as "info"
on the strength of an analogy. That judgment is written down, versioned next to
the code it judges, and thrown away on every review.

**The binary carries its own credential, and it is dead.** `mr-review` is
invoked as `mr-review -H <url>` with no token: it reads
`~/.mr-review/config.yml`, whose `gitlab_api_token` answers HTTP 401 as of
2026-08-18 and has not been touched since 14 April. Autodev's own PAT works.
30 PowerPanne tickets are abandoned with `review_failures_exhausted` for this
one reason, all still open, MR pushed and pipeline green — only the review
missing.

**Autodev already broadcasts every skill in the repo, indiscriminately.**
`SkillsInjector#existing_skills` globs `*/SKILL.md`, and `all_skills` feeds the
prompt line "charge les skills suivants". On PowerPanne that line names **23
skills**, including `hotfix` and `resolve-ticket`; on Fast **19**, including
`ship-hotfix-to-production` and `ship-mep-to-production`. Nothing bad has come
of it — the review skills trigger on review intent and the implementation prompt
does not carry any — but a review prompt cannot afford that noise, and telling
Claude to load a ship-to-production skill before reviewing is indefensible.

### What the skills refuse to do, and why that is the design

Both skills state, in bold, that they write nothing without the developer's
explicit go-ahead, and both STOP before posting. `danger-claude` runs
`claude -p --dangerously-skip-permissions`: non-interactive. There is no
developer to ask.

That is not an obstacle, it is the contract. A correct run of either skill ends
at its own STOP with a consolidated list of findings and nothing written. So:

> **the skill judges and stops; autodev posts.**

The invariant is honoured rather than bypassed — the write leaves the skill and
becomes a decision of autodev's state machine, which is deterministic, testable
and already instrumented. Nobody has to edit three skills in two other repos,
and the review stops depending on the revoked credential.

## Design

### 1. A per-project setting names the skill

New optional per-project string, `review_skill`. `mr-review` on
`modulosource/powerpanne/powerpanne/core`, `prepare-mr` on
`modulosource/ff/fast/core`, absent everywhere else.

It follows the route Autodev #63 opened for `label_attention`, which is proven:
a nullable `projects.review_skill` column, `Config::DB_BACKED_PROJECT_FIELDS`,
`Project::SCALAR_CONFIG_KEYS`, the per-project config form,
`ProjectValidator` for a YAML `projects:` entry,
`YamlProjectImporter::CONFIG_KEYS`, and its `_desc_` i18n key in `fr` **and**
`en`.

**Resolution is deliberately simpler than `detect_agent`'s.** That helper does
config, then convention, then nil — it can look for `mr-fixer.md` because the
name is the same everywhere. Here the name **is** what differs between
projects: Fast's `mr-review` is the *reviewer-side* skill and says outright
*"SKIP for — self-reviewing your OWN change … (use prepare-mr)"*. A convention
lookup for `mr-review` would therefore run the wrong role on Fast and skip its
materialization entirely. So two branches, not three:

- `review_skill` present → the skill path;
- absent → the `mr-review` binary, unchanged.

**A declared skill that is missing from the clone is a named configuration
error**, not a silent fall back to the binary. Falling back would mean
believing we run the project's process while running the other one.

### 2. The prompt names one skill and forbids writing

```
Charge le skill `<review_skill>`. Revois la merge request !<iid> contre sa
branche cible réelle, en appliquant intégralement la discipline du skill, y
compris sa passe adversariale.

Tu es en mode non interactif : il n'y a personne à qui demander une validation.
N'écris rien sur GitLab — ni discussion, ni label, ni commentaire, ni note de
ticket. Dépose tes constats consolidés dans le fichier suivant, au format
décrit ci-dessous : /tmp/autodev_review_<project>_<iid>.json
```

One skill named, not 23. The broadcast in `SkillsInjector.skills_instruction`
is tightened in the same pass: the review prompt names its own skill, and the
implementation and fix prompts stop enumerating skills that have nothing to do
with the task at hand.

### 3. The contract is a file, outside the clone

`/tmp/autodev_review_#{project_path.gsub('/', '_')}_#{issue_iid}.json` — the same
sanitizing idiom `MrFixer::FixCycle` already uses for its work directory. The shape
is the one `mr-review` already expects from Claude:

```json
{
  "verdict": "approve",
  "summary": "synthesis, plus every non-anchorable finding",
  "findings": [
    { "file": "app/models/x.rb", "line": 42, "severity": "error", "body": "…" },
    { "severity": "warning", "body": "a non-anchorable finding" }
  ]
}
```

`verdict` is `approve` or `changes_requested`. A finding with no `file`/`line`
is non-anchorable — the distinction both skills already draw. Severities are
the four they share: `error`, `warning`, `info`, `nitpick`.

**A file, not stdout.** `capture_session_and_text` already parses stdout for
the session id, a skill's prose legitimately contains fenced code blocks, and a
truncated stdout would read as an empty review — that is, as a clean MR. That is
the exact failure family Autodev #62 and #67 exist to remove. A missing or
invalid file, by contrast, is an unambiguous failure.

**Outside the clone**, like the CI logs already are: the work directory is
disposable and the fix cycle commits what it finds there.

### 4. What autodev posts

Autodev reads the file and writes two things with its own PAT: each anchorable
finding as an inline discussion, then `summary` plus the non-anchorable findings
as a single comment.

**A finding becomes an inline discussion when it is both anchorable and
blocking-class** — it carries `file` and `line`, *and* its severity is `error` or
`warning`. Everything else goes into the summary comment: an `info` or `nitpick`
even when anchorable, and an `error` that carries no line. One rule, so the two
conditions cannot be applied in the wrong order. This is the load-bearing decision of this design, and
it answers the self-review paradox: PowerPanne's skill has an author-session
guardrail stating that when the session under review wrote the code, *"the
digest loses the right to drop"* a finding — a suspected false positive must be
put to the developer, never discarded alone. Autodev has no developer. Posting
everything would have `MrFixer` dutifully "fix" false positives; letting its
Claude drop findings is precisely what the guardrail forbids. Gating on severity
does neither: nothing is dropped, and what is actionable is what both skills
already call blocking-class.

**`diff_refs` are read, not waited for.** Inline positions need
`base_sha`/`start_sha`/`head_sha`. The current `sleep 15` exists because
`mr-review` needs GitLab to have computed them; autodev now needs them itself,
so it reads them off the MR. **Absent `diff_refs` is not a review failure** — it
is a poll that could not conclude: the row is left where it is and the next
cycle re-reads (Autodev #62).

**A finding that fails to anchor is not lost.** GitLab rejects a position that
does not fall on the new side of the diff — both skills' `posting.md` document
the trap. Post one at a time, check the returned note carries a non-null
`position`, and move a finding that will not anchor into the summary comment.
No finding is ever silently dropped; the rule is PowerPanne's and it applies
here.

**The summary comment is posted last and is the completion marker.** A cycle
that dies mid-publication leaves the discussions but no summary; its presence
means the review went all the way. Same idiom as the skills' hidden-marker
upsert, and it keeps a retry from doubling the comment.

**`verdict` is reported, not obeyed.** It goes in the summary comment and nowhere
else: what routes the ticket is the set of unresolved discussions, as it does
today. So `changes_requested` carrying only `nitpick`s posts no discussion and
the next green poll completes the ticket — correctly, since nothing blocking was
found. Do not wire `verdict` into the state machine.

**Nothing downstream changes**, and that is the point: the inline discussions
are exactly what `MrFixer` consumes. `changes_requested` with N anchorable
findings produces N unresolved discussions, so the next green poll routes to
`fixing_discussions` and autodev fixes its own review. The existing loop is
preserved as-is.

### 5. What counts as a review failure

Failures, which increment `review_failure_count` — threshold 5 and
`give_up_reviewing` unchanged:

- `danger-claude` exits non-zero;
- the contract file is missing;
- its JSON does not parse, or does not match the schema.

**Not a failure:** zero findings with `verdict: approve`. A clean review is a
successful review. Stated explicitly, or a healthy project eventually spends its
budget.

**Emphatically not a failure:** a GitLab error while *autodev* posts. It raises
`ApiUnavailableError`, the poll ends at its boundary, the row is re-read next
cycle, and it **does not** increment `review_failure_count`. First half is
Autodev #62 and #67, second half is #71: a cycle that could not act does not
spend a budget. The ordering is what makes it true — read `diff_refs`, post,
and only then increment `review_count`.

Two things stay untouched. `mr_review_timeout` now bounds a `danger-claude` call
instead of the binary, but its semantics and its role in
`HealthReport#longest_worker_timeout` are identical; renaming it would ripple
through config, database and docs for nothing. And Autodev #60's health check
counts the `review_failed` / `review_failures_exhausted` activity keys, so **the
alert that would have caught the revoked token covers the skill path too**.

### 6. The binary stays

`review_skill` absent → `run_mr_review_command`, untouched, with its own
credential. It remains an optional Homebrew dependency; the boot warning should
only fire when some project actually relies on it.

Once PowerPanne and Fast are on the skill path, the revoked token no longer
blocks them. That does not excuse leaving it revoked — Autodev #74 stands for
any project still on the binary — it only removes the urgency.

## Testing

- The skill path posts what the contract says: an `error` with `file`/`line`
  becomes an inline discussion, a `nitpick` does not.
- A finding that will not anchor lands in the summary comment instead of
  vanishing.
- Zero findings with `verdict: approve` is a success: `review_count`
  incremented, `review_failure_count` reset, no discussion posted.
- A missing or malformed contract file is a failure and increments the counter.
- A GitLab error while posting does **not** increment the counter and leaves the
  row in `checking_pipeline`.
- Absent `diff_refs` leaves the row untouched and does not count as a failure.
- The fallback still runs the binary when `review_skill` is absent.
- A declared skill missing from the clone is a named configuration error.
- The summary comment is posted last, and a second pass does not double it.

Every test file must pass run on its own (Autodev #64). Any user-facing string
goes through `Locales.t` in `fr` and `en`, and the derived-key guard of
Autodev #68 covers the new keys.

## Out of scope

**Materialization.** Size, coverage zone, reviewer draw, ticket notes,
`MR::ReadyForReview` / `# TO REVIEW`. They need the project's `app` container
for `bin/ci/*` and, on PowerPanne, the 50cent MCP for absences — whose absence
that skill treats as blocking. They are also the team-process writes the skills'
invariant most clearly protects. Autodev posts the technical feedback and
nothing else.

**Verifying the fixes.** `MrFixer` fixes a discussion and resolves it; the
resolution *is* the claim that it is fixed, and nothing checks it. A green
pipeline does not prove a review comment was addressed. PowerPanne's skill has
the parent session verify each fix directly; autodev has no equivalent. This is
pre-existing — it is what happens with `mr-review` today — but this design makes
it more visible, because the findings become sharper and more numerous. Its own
ticket.

**Re-reviewing the fixed commit.** Deliberately not done, and the doctrine is
the project's own: *"an adversarial agent produces findings on any code, so a
second pass returns a fresh crop regardless of quality and the loop never
converges."* Autodev's existing shape already matches — the review runs once.

**`MAX_REVIEW_ROUNDS` is dead code.** The only writers of `review_count` are
the review's own increment (0 → 1, once) and the two reentry paths (which set 1
or 0). It never exceeds 1, so `green_branch`'s `:review_limit` branch and its
`review_limit_reached` abandon are unreachable; the tests only get there by
setting `review_count: 3` by hand. What actually bounds the fix loop is
discussion stagnation detection. Its own ticket — this spec neither relies on
the constant nor removes it.

## Constraints

TDD, RuboCop green at the 46-offence baseline, `CHANGELOG.md` `[Unreleased]`,
Conventional Commits, i18n `fr` and `en` for every user-facing string, and
`CLAUDE.md` plus `docs/usage/*` updated where they describe the review step.
