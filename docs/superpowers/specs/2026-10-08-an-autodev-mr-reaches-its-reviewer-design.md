# An autodev merge request reaches its reviewer (Autodev #90)

## The gap, measured

Autodev delivers a request by posing `label_done` on the **ticket**
(`Development::Awaiting Feature Review` on powerpanne/core) and handing the
ticket back to its author. Nothing is written on the **merge request**: no
`MR::` label, no reviewer, no assignee beyond whatever GitLab defaulted. A human
merge request on the same project arrives with all of that, written by the
author-side `mr-review` skill's materialization (`bin/ci/mr_materialize`).

Measured on 25/09/2026 (ticket comment): of 73 autodev merge requests still open
on powerpanne/core, 35 sat in `Development::Awaiting CR`, 2 of them assigned to a
developer, 25 to the ticket's author, a CSM or a PO, the other 8 to the bot or to
nobody. Measured again on 08/10/2026 over the last 100 merge requests touched on
the project (`glab api …/merge_requests?state=all&per_page=100`): 72 carry an
`MR::` label; 50 are autodev's (author `group_181_bot_…`) and 38 of those carry
one — **posted by hand by a human afterwards**: the label events of !11413 and
!11286 show `ciappa_m` adding `MR::Size::M`, two `MR::Reviewer::<FirstName>`
labels and then `MR::ReadyForReview` on 07/10/2026, with one drawn developer as
assignee and the other as reviewer. That catch-up is the shape this ticket
automates.

## What this ticket does (owner's scope, Q1 read as (c)(i))

At the moment autodev **delivers** — the moment it poses `label_done`, in
`PipelineMonitor#finalize_green_done` — and for a project that declares it,
autodev:

1. runs the project's own measurement and draw scripts **inside the project's
   container**, on a clone of the merge request's branch;
2. writes, **itself, with its own GitLab token**, on the merge request:
   `MR::Size::<class>`, `MR::TestCoverage::<zone>` (omitted when unmeasured),
   one `MR::Reviewer::<FirstName>` per drawn developer, the reviewer and the
   assignee, and `MR::ReadyForReview` **last**;
3. reads every write back before going on.

The skill and its scripts compute; autodev writes — the Autodev #74 invariant,
one step further. Autodev does **not** run `bin/ci/mr_materialize`, never
rewrites the merge request's title or description, posts no review summary and
writes no ticket note. The catch-up of A#89 and A#124 is not here (Q3): the
owner does it by hand after deployment.

### Why `finalize_green_done` and nowhere else

`test/retry_resumes_it_does_not_deliver_test.rb` declares the four callers of
`apply_label_done`. Only `finalize_green_done` delivers to review: green pipeline,
reviewed, no unresolved thread, merge request still open. The three others are a
merged merge request (nothing left to review), a todo label reposed on merged
work, and a question answered on the ticket (no merge request). The handoff runs
as the **last** statement of `finalize_green_done`, after the handback, the
`finished_at` stamp, the `done_nominal` comment and the activity entry, so
nothing it does can skip any of them (the Autodev #126 lesson: a write after a
terminal transition must not stop the sequence).

## Declaration — per project, three command arrays

No PowerPanne path lives in autodev. Three new per-project keys, stored as JSON
array columns on `projects` exactly like `post_completion`, accepted in
`config.yml` and editable from the dashboard's project form:

| Key | Role | Output contract (last JSON line of stdout, exit 0) |
|---|---|---|
| `review_size_command` | measures the size | `{"class": "XS"…"XXL"}` |
| `review_coverage_command` | measures the coverage zone | `{"zone": "high"\|"medium"\|"low"\|"red"\|"unmeasured"}` |
| `reviewer_draw_command` | draws the reviewers | `{"drawn": [usernames], "postponed": bool}`; exit 2 = no draw possible |

`review_size_command` is the switch: a project that declares none of the three
gets nothing written, as today. Declaring coverage or draw without size is
rejected (YAML validator and model alike), because the draw is routed on the
size and nothing is written without one.

Arguments carry placeholders, substituted per element: `%{mr_iid}`,
`%{base_sha}`, `%{head_sha}`, `%{source_branch}`, `%{target_branch}`,
`%{mr_author}` (the merge request author's username) and, for the draw,
`%{size}` (the measured class). One whole-element placeholder, `%{red_flag}`,
becomes `--red` when the measured zone is `red` and **disappears** otherwise —
`reviewer_draw` takes a bare flag.

PowerPanne's declaration (to be entered by the owner, not by this ticket):

```yaml
review_size_command: ["mise", "x", "--", "bin/ci/mr_size", "--mr", "%{mr_iid}", "--json"]
review_coverage_command: ["mise", "x", "--", "bin/ci/mr_coverage", "--mr", "%{mr_iid}",
                          "--base", "%{base_sha}", "--head", "%{head_sha}", "--json"]
reviewer_draw_command: ["mise", "x", "--", "bin/ci/reviewer_draw", "--size", "%{size}",
                        "%{red_flag}", "--author", "%{mr_author}", "--json"]
```

`mise x --` is the project's business: inside danger-claude's container a
non-interactive shell has no mise shims on `PATH` (danger-claude's own system
prompt says so), so the project declares how its Ruby is reached.

## "Inside the project's container" — measured, not assumed

The container autodev already runs a project in is danger-claude's: the clone is
mounted at `/home/claude/<dir>`, `mise` resolves the project's pinned Ruby, and
`glab` 1.97.0 is installed. `danger-claude -s "<command>"` runs a command there
(`bash -c`). Measured on 08/10/2026 on a local danger-claude 0.5.10 image, on a
`--depth 1` clone of !11631's branch, the three PowerPanne scripts declared
above:

| Script | Result |
|---|---|
| `ruby -v` | `ruby 3.2.3` (the project's `mise.toml`) |
| `mr_size --mr 11631 --json` | `{"class":"M",…}` exit 0 — the label a human posted on !11631 is `MR::Size::M` |
| `mr_coverage --mr 11631 --base … --head … --json` | JSON, exit 0, `source: cobertura` |
| `reviewer_draw --size M --author billau_l --json` | `{"drawn":["alexan_a","bernar_a"],"count":2,"pool_size":3,"absent_count":0,"postponed":false}` exit 0 |

Three facts this measurement made, each of which the implementation carries:

1. **The clone needs both ends of the diff.** `--depth 1` holds the head only and
   both size and coverage run `git diff <base> <head>`. `git fetch --depth 1
   origin <base_sha> <head_sha>` is accepted by this GitLab (measured) and makes
   both commits local.
2. **The container's Ruby reads US-ASCII without a locale**: `mr_size` died on
   `"\xC3" on US-ASCII` until `LANG=C.UTF-8` was set.
3. **git refuses the mounted clone as "dubious ownership"** when the host and
   container uids differ (`fatal: detected dubious ownership`), and `mr_size`
   then fails with `Could not access '<sha>'`. `GIT_CONFIG_COUNT=1`,
   `GIT_CONFIG_KEY_0=safe.directory`, `GIT_CONFIG_VALUE_0=*` (command-line
   scope, which git honours for `safe.directory`) fixed it. Whether bobette's
   Docker Desktop maps uids so that this never happens there was **not
   measured** — read access to production was refused in this session — so the
   variable is set unconditionally; it is inert where ownership already matches.

### The credential reaches the scripts through a file, never argv

The scripts read GitLab through `glab api --hostname source.modulotech.fr`.
`GITLAB_TOKEN` in the environment overrides any stored glab credential (measured:
a bogus `GITLAB_TOKEN` turns a working `glab api user` into `401 Unauthorized`).
danger-claude has no `-e`; the token is therefore written to a `0600` tempfile,
mounted read-only (`-v <file>:/autodev/handoff.env:ro`) and sourced by the
command (`set -a && . /autodev/handoff.env && set +a && exec <argv>`). Never in
argv: argv is readable by `ps` for the whole run (Autodev #10, #80). The token is
autodev's own; it is already inside every danger-claude container of the project,
in the clone's `origin` URL, so nothing new is exposed. The file is deleted in
an `ensure`.

The declared argv is shell-escaped element by element (`Shellwords.escape`) —
`bash -c` would otherwise reinterpret it.

## The writes, and the rules each one follows

All writes go through autodev's `@client` on the merge request autodev holds
(`issue.mr_iid`, author = the bot).

**Labels.** GitLab CE has no scoped-label exclusivity, so the vocabulary
`MR::Size::`, `MR::TestCoverage::`, `MR::Reviewer::` is managed
remove-then-add, exactly like `MrMaterialize::LabelPlan`: every other label under
the prefix is removed, the target added. A dimension not measured is left
untouched. Zone → token is LabelPlan's table (`high→High`, `medium→Standard`,
`low→Low`, `red→Red`); an unknown zone or class is a measurement failure, never
a label (LabelPlan's own reason: GitLab auto-creates any label it is given).

**Reviewer labels take the first name, as humans write them.** The skill says
`MR::Reviewer::<FirstName>`, `reviewer_draw` returns usernames. The labels that
exist on powerpanne/core (measured 08/10/2026) are `MR::Reviewer::Alexandre`,
`Antoine`, `Corentin`, `David`, `Lucas`, `Matthieu`, `Team`, and every one of
the 25 labelled merge requests listed with their reviewer labels uses that form. Autodev resolves each drawn username through
GitLab (`users?username=`), takes the first word of its `name`
(`billau_l` → "Lucas Billaudot" → `Lucas`, `alexan_a` → `Antoine`, `bernar_a` →
`Alexandre`, `bourea_d` → `David`, all measured) and **requires the resulting
label to already exist on the project** — derived from data, a wrong derivation
would otherwise mint a label. A username GitLab does not know, or a label that
does not exist, means no reviewer is written.

**One reviewer, one assignee** (GitLab CE holds one of each; a second reviewer
is silently dropped). One drawn developer is both. Two: the first drawn is the
reviewer, the second the assignee — the shape the human handoffs above already
have (two labels, one developer in each role). Autodev never escalates to
`MR::Reviewer::Team`: escalation is "the skill recommends, the developer
decides", and there is no developer here.

**A reviewer already present is kept.** When the merge request already carries a
GitLab reviewer or any `MR::Reviewer::*` label — a previous delivery of the same
request, or a human — the draw is not run and nothing reviewer-shaped is
written. A re-delivery after a fix round must not hand the review to somebody
else, and a human's choice is not autodev's to undo.

**Every write is read back.** One `merge_request` read after the label and
assignment writes: every added label present, every removed one absent, the
reviewer list exactly `[reviewer]`, the assignee the one written. Anything else
is "did not land", named in the activity note, and stops before
`MR::ReadyForReview`.

**`MR::ReadyForReview` is last and conditional**: posted only when the size
was measured, the reviewer step (when declared) designated somebody or kept
somebody already there, and every write read back — the skill's own rule
("posted last and only once everything above succeeded"). Coverage does not
gate it: a coverage script that fails is read like an `unmeasured` zone, the
skill's rule for that case (the label is omitted, nothing else changes), and the
activity entry shows `—` for it. Ready is read back too.

## Outcomes — one activity entry each, never a guessed reviewer

| Outcome | Written on the merge request | Activity entry |
|---|---|---|
| Everything declared succeeded, reviewer drawn now | size, coverage, reviewer labels, reviewer, assignee, Ready | `review_handoff_ready` |
| Same, reviewer already present (kept) | size, coverage, Ready | `review_handoff_ready_reviewer_kept` |
| Same, project declares no draw | size, coverage, Ready | `review_handoff_ready_no_draw` |
| Draw exit 2 (People absence check failed) | size, coverage | `review_handoff_no_reviewer_absences` |
| Draw `postponed` (pool too small) | size, coverage | `review_handoff_no_reviewer_postponed` |
| Draw failed otherwise / unreadable output | size, coverage | `review_handoff_no_reviewer_draw_failed` |
| Drawn user or its label unknown | size, coverage | `review_handoff_no_reviewer_unresolved` |
| Size not measured (script failed, no diff_refs) | nothing | `review_handoff_not_measured` |
| A write did not read back | what landed | `review_handoff_not_landed` |
| Anything else (clone, GitLab outage, container) | what landed | `review_handoff_failed` |

On exit 2 the owner's rule is literal: no reviewer, never a guessed one, and
the note says the absence check could not be made. The skill forbids working
around it, and so does autodev.

The handoff never raises: it runs after a terminal transition, and an
exception out of `finalize_green_done` would land in `PipelineMonitor#check`'s
error log and nowhere a human reads. Every failure becomes its activity entry.
It never changes the row's status, `needs_attention`, or the ticket's labels or
assignee: the delivery happened; what failed is a courtesy on the merge request,
and the activity note on the ticket is where its owner reads it.

There is no retry. A handoff that failed is re-run by the next delivery of the
same request (a todo label reposed → re-entry → green → `finalize_green_done`),
and the rules above make that second run safe: remove-then-add labels converge,
and a reviewer already present is kept.

## Cost

One clone (`--depth 1`, ~15 s measured for powerpanne/core from this machine)
plus one fetch, three container runs (~3.5 s each measured, once the project's
Ruby is in danger-claude's mise volume), and at most five GitLab requests
(one merge request read, one label list, one user read per drawn developer, two
writes and two read-backs). Once per delivery, inside the `check_pipeline` job
that delivered. Each container run is bounded by the project's `dc_timeout`
(`ProcessRunner#run_with_timeout`).

## Assumptions written down

- The danger-claude container is "the project's container" of the owner's
  answer: it is the only container autodev runs project code in, and the
  scripts ran there as measured. PowerPanne's `bin/dc exec app` compose stack
  does not run on bobette.
- bobette's danger-claude image and mise volume behave like the local ones
  measured here (same danger-claude version is the owner's to confirm).
- First drawn = reviewer, second = assignee: an order nothing in the skill or
  the scripts fixes; the human handoffs read do not show a stable order either.
- `%{mr_author}` (the bot's username) is passed as `--author`: the bot is in no
  roster, so excluding it changes nothing, and the ticket's author is not the
  code's author.
