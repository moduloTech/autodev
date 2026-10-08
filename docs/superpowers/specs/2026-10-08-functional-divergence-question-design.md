# A functional divergence found in review becomes a question on the ticket (Autodev #121)

## Problem

`needs_clarification` is reachable from `checking_spec` alone (`spec_unclear`). Once the
implementation has started, nothing hands the request back to the person who asked for it.
`MrFixer` has one answer to every unresolved review thread — correct the code — so a thread
that is a *product* decision locks it into a loop of corrections that cannot conclude.

Measured case, powerpanne/core#14746 (A#111, MR !11409). The requester had answered the
clarification ("an interface to choose a period of up to one month", "filter on the invoice's
creation date"); autodev delivered a monthly Sidekiq cron filtering on `invoiced_at`. The review
skill saw both gaps and opened threads titled « Divergence fonctionnelle (à valider par le PO) ».
MrFixer then ran rounds 3 to 6 on them (29/08/2026, 04:54 → 14:47), each producing only code
comments ("UI différée en attente d'arbitrage PO") and "Correction non concluante". The request
was abandoned on an unrelated pipeline stagnation at 17:00; nobody on the product side knew.

Measurements:

- `glab api …/merge_requests/11409/discussions` (08/10/2026): the four « Divergence
  fonctionnelle » threads are positioned (inline) MR discussions; the review was posted twice,
  so two pairs are identical. The SonarQube threads on the same MR are **unpositioned and
  `resolvable: true`** — an unpositioned MR discussion is a resolvable thread.
- Production `activity_events` (08/10/2026): the text « Divergence fonctionnelle » appears in
  `danger_claude` rows of three requests — powerpanne #14746 (27 rows), #15839 (2), #15673 (1).
  It exists only as free text written by PowerPanne's review skill; nothing in autodev reads it.

## Decisions (owner, Q4/Q5)

1. **The signal is a structured field of the review contract**, never a heuristic on
   "non-conclusive" corrections: each finding of the JSON the review skill writes carries
   `category: "functional" | "code"`.
2. **The question goes on the GitLab ticket** (not the MR), addressed to the requester, with
   what was delivered, the gap, and the decision expected.
3. **The wait reuses the #86 machinery**: `needs_clarification`, `clarification_requested_at`,
   the entry label reposed, `ClarificationWatch`'s reasons and reach, `ClarificationResume`.
4. **The answer resumes on the same MR**, in `fixing_discussions`, with the answer in the fix
   context — never `pending`, which is a full re-implementation.
5. **The asking round counts toward nothing**: neither `stagnation_discussions` nor
   `fix_rounds_exhausted`.

## Design

### The contract (`ReviewContract`, `SkillReviewer#review_prompt`)

- `ReviewContract::CATEGORIES = %w[functional code]`, `FUNCTIONAL = 'functional'`.
- A finding without `category` is `code`: every skill written before this ticket keeps
  working. A present but unknown value is an `InvalidError` — the same strictness as
  `severity`, because a typo there would silently turn a product question into a code fix.
- The rule that makes a finding a thread becomes: blocking-class **and** (anchorable **or**
  functional). A functional blocking finding with no line is still a decision somebody has to
  take, so it must become a resolvable thread rather than prose in the summary — otherwise
  `MrFixer` never sees it and `unanchored_verdict?` gives the request up on it.
- The prompt documents the field and what "functional" means: the delivered *behaviour*
  differs from what the ticket or its clarifications asked for, and only the requester can
  decide — as opposed to a defect in how the code does what was asked.

### The publication (`ReviewPublisher`)

- `ReviewPublisher::FUNCTIONAL_MARKER = '<!-- autodev:functional -->'` heads the body of every
  thread posted for a functional finding, followed by a localized line
  (`review_functional_finding_label`) telling the reader autodev will ask the requester rather
  than change the code. The marker is how `MrFixer` recognises the thread on a later poll:
  the category has to survive in GitLab, since the review and the fix run in different jobs.
- A functional finding is posted positioned when it has a location, exactly like a code
  finding. When it has none, **or GitLab refuses its position**, it is posted as an
  **unpositioned** discussion instead of being demoted to the summary: it is still a thread,
  it still holds the delivery, and it still counts as `posted` for `unanchored_verdict?`.
  Only if that fallback is refused too (`InvalidRequestError`) is it demoted, as before.

### The question (`MrFixer::FunctionalQuestion`)

At the top of a round, after `settle_pending_resolutions` and before `execute_fix_cycle`:

- a thread is **functional** when its first note carries the marker;
- it is **unasked** when its id is not in `issues.functional_questions`;
- if any unasked functional thread exists, the round asks and stops. **No thread of the round
  is fixed** — the code threads wait for the resumed round, because the product decision may
  change the very code they are about. Nothing is counted: `fix_round`,
  `discussion_fix_round` and `stagnation_signatures` are left as they were, because the
  method returns before `execute_fix_cycle`, which is where all three are written.

Asking, in this order:

1. read the ticket (`GitlabHelpers.answer(:issue)`) for the author's username, to address
   the requester by `@mention`;
2. post the question on the ticket through `GitlabHelpers.answer(:issue_note)` — a raising
   post, unlike `notify_issue`: a question that was not posted must not park the row. An
   outage aborts at `MrFixer#fix`'s boundary and the next cycle asks again;
3. assign `functional_questions` (merged with the ids asked now, each with the time asked),
   `clarification_resume_to = 'fixing_discussions'`, `clarification_requested_at`, then fire
   `functional_question!` (`fixing_discussions → needs_clarification`), so the columns and the
   status are written by the same `save!`;
4. repose the entry label (`apply_label_todo`, errors swallowed — the #75 rationale) so the
   row stays in `dispatch_new_issues`' population and `ClarificationWatch` reads it;
5. one activity entry, `functional_question_asked`.

The question (`functional_question_header`, `_footer`) names the MR that was delivered, lists
each gap — the thread's body without the marker and the label line — and asks for the decision,
saying the MR will resume with the answer.

### The resume

- `clarification_received` gains a first, guarded transition:
  `needs_clarification → fixing_discussions` when `clarification_resume_to ==
  'fixing_discussions'` and the row has an MR; otherwise `→ pending`, unchanged. Every caller
  of the event — the live path and the sweep — therefore lands on the same destination.
- `PollDispatcher#skip_existing?` enqueues `:process` only when the resumed row is `pending`;
  `ClarificationSweep#apply!` likewise. A row resumed to `fixing_discussions` is picked up by
  `dispatch_discussions`, later in the same cycle.
- The first round after the resume reposes `label_doing` (errors swallowed) and clears
  `clarification_resume_to`. A todo label on an active row is not a handover for
  `LabelHandover` (`doing_dropped?` is false while a todo label is present, and the todo
  labels are `configured_labels`), so the window between the resume and that round closes
  nothing.
- In every later round, a thread whose id is in `functional_questions` is an ordinary thread
  to fix, and its prompt carries the human notes posted on the ticket after it was asked
  (`functional_answer_section`). It is never asked again.

### Clearing

`functional_questions` and `clarification_resume_to` are cleared by `reenter` (the branch is
rebuilt, like `pending_resolutions`); `clarification_resume_to` also by
`reenter_to_check_pipeline`.

## Assumptions

- The requester is the ticket's author. The question `@mention`s them; the ticket stays
  assigned to autodev, as for a spec clarification, because `dispatch_new_issues` discovers by
  assignee.
- An answer is read on the **ticket** only, like every clarification (`ClarificationResume`);
  a reply on the MR thread does not resume the row.
- An answer of the kind "keep it as delivered" is fed to the fixer like any other. If the
  fixer then changes nothing, the thread stays open (`discussion_unchanged`) and the ordinary
  bounds apply from there: those rounds *do* count, because the decision has been taken.
- The `mr-review` binary path carries no contract and is untouched.

## Out of scope

- Resolving a functional thread with a reply when the requester validates the divergence.
- Detecting functional divergences on the binary path, or from verifier verdicts.
