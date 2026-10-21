# Plan — the ticket context keeps autodev's questions (Autodev #137)

Spec: `docs/superpowers/specs/2026-10-21-the-context-keeps-autodev-questions-design.md`.

One lane (the change is four small files and one test file; a second lane would cost
more than it returns).

## Contract

- `lib/autodev/context_notes.rb`, top-level `module ContextNotes` (like `HumanActivity`),
  required from `lib/autodev.rb` before `gitlab_helpers`:
  - `QUESTION_MARKER = '<!-- autodev:question -->'`, `ANSWER_MARKER = '<!-- autodev:answer -->'`,
    `MARKERS`.
  - `SIGNATURE = '**autodev**'`.
  - `KEPT_HEADER_KEYS = %i[spec_unclear_header functional_question_header question_answered_header]`,
    `LOCALES = %i[fr en]`.
  - `ContextNotes.in_context?(note)` → false for a system note; true for a note without the
    signature; for a signed note, true iff a marker is in the body or its first non-blank
    line matches one of the derived header patterns.
  - `ContextNotes.header_patterns` → the 6 regexps, derived from `Locales.lookup`.
  - `ContextNotes.chronological(notes)` → notes sorted by `[Time.parse(created_at), id]`.
- `IssueFormatter.append_comments` keeps `ContextNotes.in_context?` notes, in
  `ContextNotes.chronological` order.
- Writers append `"\n\n#{marker}"` to the body:
  `SpecChecker#notify_clarification_questions` and
  `MrFixer::FunctionalQuestion#functional_question_body` → `QUESTION_MARKER`;
  `QuestionHandler#post_answer` → `ANSWER_MARKER`.
- `HumanActivity` unchanged.

## Tests — `test/the_context_keeps_autodev_questions_test.rb`

Through `GitlabHelpers.fetch_issue_context` with a fake client (`issue`, `issue_notes`
returning a paginated list in GitLab's **descending** order, `issue_links`):

1. An unmarked clarification question (fr) followed by a human answer: both in the
   context, question before answer.
2. Same in `en`.
3. The activity note and a failure notice (`error_generic`) and a start notice are absent.
4. The PP#14746 shape: the real header line of note 832858, item 3 verbatim, preceded by
   the `processing_started` notice and followed by Bryan's answer and the 28/08 status
   notices; context holds question then answer, none of the notices.
5. A marked note whose first line is not a known header is kept (marker first).
6. The functional question header with a mention and an MR iid, unmarked, is kept.
7. The question_answered header is kept.
8. A status notice quoting a question header on a later line is dropped.
9. Writers: each of the three bodies ends with its marker and the full body passes
   `in_context?`; a status notice built through `Locales.t` does not.
10. Derivation: every `KEPT_HEADER_KEYS × LOCALES` template yields a pattern
    (6 patterns), and each matches its own interpolated header.

Gates: full suite, the new file alone, rubocop on the tree, CHANGELOG `[Unreleased]`,
CLAUDE.md paragraph on the context filter.
