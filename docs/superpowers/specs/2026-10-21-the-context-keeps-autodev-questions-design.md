# The ticket context keeps autodev's questions (Autodev #137)

## Problem

`GitlabHelpers::IssueFormatter.append_comments` builds the `## Comments` section of
every prompt context (spec check, implementation, MR fix, pipeline fix, question
investigation). It dropped every note whose body contains `**autodev**`, which is
autodev's signature on everything it posts — including the questions it asks the
requester. The context therefore kept the answer and lost the question.

Measured on POWERPANNE#14746 (A#111), read with `glab api …/issues/14746/notes` on
21/10/2026: note 832858 (29/06/2026, the bot) opens with
`:thinking: **autodev** (v1.0.0.alpha.32) : la specification necessite des precisions avant implementation.`
and defines the options (a) and (b); note 832966 (Bryan Alves, the same day) answers
`3. (b) Une interface utilisateur permettant de choisir une période jusqu'à 1 mois`.
The spec check of 28/08 read the second without the first. That this caused its
"Specification claire" is plausible, not demonstrated (the #122 bench did not reproduce it).

Reach, read-only on the production database on 21/10/2026 (`activity_events`
transitions by event): `spec_unclear` 17 times on 16 requests, `functional_question`
once, `question_answered` 3 times on 3 requests — out of 167 requests on record. Any
prompt built on those requests after the question (spec check, implementation, fixes)
read the requester's answer without it.

## Decision (owner, 21/10/2026)

Kept in the context, in chronological order with the human notes:

| autodev note | Locale key of its first line | Posted by |
|---|---|---|
| clarification questions | `spec_unclear_header` | `SpecChecker#notify_clarification_questions` |
| functional question (#121) | `functional_question_header` | `MrFixer::FunctionalQuestion#functional_question_body` |
| answer to a question ticket | `question_answered_header` | `QuestionHandler#post_answer` |

Dropped, as before: the activity note (`ActivityLogger`), every status notice
(start, MR created, done, failure, fix success, abandon, stop, takeover/reclaim,
screenshots), and system notes.

`HumanActivity#human_note_after?` is **not** changed: it answers "did a person post",
and an autodev question is not a person posting.

## Order — the context was not chronological

The owner's answer asks for the chronological order to be *kept*, so that an answer
follows its question. Measured, it was not chronological: `append_comments` calls
`issue_notes(project, iid, per_page: 100)` with no `sort`, and GitLab's default for
that endpoint is `order_by=created_at, sort=desc`. `glab api
"…/issues/14746/notes?per_page=5"` on 21/10/2026 answered notes 878297 (19/10),
878295 (19/10), 877772 (16/10)… — newest first. Every prompt context built so far
listed the comments newest first, so even with the question kept, Bryan Alves'
answer would have been read *before* the question it answers.

`append_comments` therefore orders the notes it keeps by `created_at`, then `id`,
ascending — locally, not through the request's `sort` parameter, so that the order
does not depend on a query parameter every test double ignores, and the fetch stays
the exact request `HumanActivity#human_comment_since?` makes on the same endpoint.

## Recognition

A note is autodev's when its body contains `**autodev**` (unchanged). Among those, a
note is kept when either:

1. **its body carries a context marker** — `<!-- autodev:question -->` (clarification
   and functional questions) or `<!-- autodev:answer -->` (answer to a question
   ticket). Checked first. The three writers append it from now on, after the footer,
   on a line of its own: an HTML comment is not rendered by GitLab, so the visible note
   is unchanged;
2. **or its first line matches the header of one of the three keys, in `fr` or `en`**.
   Needed because every note already posted carries no marker — PP#14746's question
   of 29/06 must come back. The pattern is derived from the locale table, not
   restated: each template is split on its `%{…}` placeholders, the literal parts are
   escaped, `%{tag}` becomes `**autodev**` followed by an optional ` (v…)` version, and
   every other placeholder (`%{mention}`, `%{mr_iid}`, `%{count}`) matches anything on
   the line. The whole first line must match.

Measured stability of what the derivation reads: the three headers are worded the
same since they were introduced (`git show 1427fce^:lib/autodev/locales.rb` — the
pre-YAML Ruby table holds the same strings), and `autodev_tag` has been
`**autodev** (v<VERSION>)` since `f4f5a8e` (01/04/2026). A future rewording of a header
keeps the notes posted after it (they carry the marker) and loses only the earlier
unmarked notes of the old wording — written here so that whoever rewords a header
knows to keep the old wording in the pattern list.

The marker and the header are recognised by `ContextNotes` (`lib/autodev/context_notes.rb`),
the one definition both the writers (the marker constants) and the reader
(`ContextNotes.in_context?`) use.

## Assumptions

- A note kept in the context is rendered exactly like a human note (`### <author name>
  (<created_at>)` then the body, marker included). The body's own `**autodev**` tag says
  who wrote it; no extra label is added.
- A human note that contains `**autodev**` (a quote of an autodev note) is kept only if
  it itself matches the marker or header rule — the pre-#137 behaviour for everything
  else.
- Only the first line is compared to the headers: a status notice that quotes a header
  further down is not a question.

## Owner may reverse

- **Two markers rather than one.** `<!-- autodev:question -->` for both questions,
  `<!-- autodev:answer -->` for the answer. Alternative: a single
  `<!-- autodev:context -->`, which names the filter rather than the note's nature.
  On PP#14746 both give the same context (the 29/06 note carries no marker and is
  recognised by its header). Two markers keep the nature readable to a later reader
  of the ticket's source, like `review_publisher.rb`'s `review` / `functional`.
- **Marker at the end of the body rather than first.** Alternative: as the first line.
  Same context on PP#14746; at the end, the first line of the note stays its visible
  header, which is what the header rule and any human reading the source expect.

## Out of scope

- Replaying the spec check on PP#14746 in the danger-claude container (optional per the
  owner; not done).
- Rewriting how the context presents autodev's notes (author line, labels).
- The order of the MR discussions section (`fetch_mr_discussions_context`), which reads
  a different endpoint.
