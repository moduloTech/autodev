# Plan — an autodev merge request reaches its reviewer (Autodev #90)

Spec: `docs/superpowers/specs/2026-10-08-an-autodev-mr-reaches-its-reviewer-design.md`.

One lane (server only, no view beyond the existing generic form): the change is
one module plus its declaration plumbing, and splitting it would make two agents
share `Project`, the locale files and the test helper.

## Frozen contract

- Migration `20261008090001_add_review_handoff_commands_to_projects.rb`: three
  nullable `json` columns on `projects` — `review_size_command`,
  `review_coverage_command`, `reviewer_draw_command` (same type as
  `post_completion`).
- `Project::LIST_CONFIG_KEYS` gains the three keys (→ form, controller cast,
  `to_project_config`, `validate_string_arrays`). `Project` validates the
  pairing: coverage or draw without size is invalid
  (`validate_review_handoff_pairing`).
- `Config::DB_BACKED_PROJECT_FIELDS`, `YamlProjectImporter::CONFIG_KEYS`,
  `Web::Views::ProjectEdit::SECTIONS` (execution section) gain the three keys;
  `web_project_edit_desc_<key>` fr + en.
- `ProjectValidator.validate_review_handoff!(project_config, path)`: each key, if
  present, a non-empty array of strings; coverage/draw require size →
  `ConfigError`.
- `PipelineMonitor::ReviewHandoff` (`lib/autodev/pipeline_monitor/review_handoff.rb`),
  included in `PipelineMonitor`; public-to-the-class entry
  `hand_off_for_review(issue)`, called as the **last** statement of
  `finalize_green_done`. Never raises.
- Constants on `PipelineMonitor::ReviewHandoff`: `SIZE_CLASSES`
  (`XS S M L XL XXL`), `COVERAGE_ZONE_LABELS`
  (`high→High medium→Standard low→Low red→Red`), `SIZE_PREFIX`,
  `COVERAGE_PREFIX`, `REVIEWER_PREFIX`, `READY_LABEL`, `ENV_MOUNT`
  (`/autodev/handoff.env`), `RED_FLAG` (`%{red_flag}`).
- Activity keys (`activity_<key>` in `activity.{fr,en}.yml`): `review_handoff_ready`,
  `review_handoff_ready_reviewer_kept`, `review_handoff_ready_no_draw`,
  `review_handoff_no_reviewer_absences`, `review_handoff_no_reviewer_postponed`,
  `review_handoff_no_reviewer_draw_failed`, `review_handoff_no_reviewer_unresolved`,
  `review_handoff_not_measured`, `review_handoff_not_landed`, `review_handoff_failed`.

## Steps (TDD, each test red before its code)

1. **Declaration.** Migration; `Project` keys + pairing; validator; importer;
   config list; form section; locale descs. Tests: model accepts/rejects,
   `to_project_config` emits the arrays, validator rejects each malformed shape
   and the pairing, importer carries the keys.
2. **Commands.** `handoff_argv(template, vars)` substitutes the placeholders per
   element and drops `%{red_flag}` unless red; `run_in_container(work_dir, argv)`
   builds `danger-claude -v <envfile>:/autodev/handoff.env:ro -s '<script>'`
   with each element `Shellwords.escape`d, env file 0600 holding
   `GITLAB_TOKEN`, `GITLAB_HOST`, `LANG=C.UTF-8` and the three
   `GIT_CONFIG_*` safe.directory lines, removed in `ensure`. Token never in argv.
   Parse = last stdout line that parses as a JSON object.
3. **Clone.** `clone_and_checkout(work_dir, branch)` then
   `git fetch --depth 1 origin <base> <head>`; work dir removed in `ensure`.
4. **Measure.** size (required; unknown class = not measured), coverage
   (optional; failure or `unmeasured` = omitted), draw (only when declared and no
   reviewer present): exit 0 + `drawn` non-empty + not postponed → usernames;
   exit 2 → absences; postponed → postponed; else draw_failed.
5. **Resolve.** username → `users(username:)` → id + first name; label
   `MR::Reviewer::<First>` must be in `labels(search: 'MR::Reviewer::')`.
6. **Write + read back.** One `edit_merge_request` with `add_labels` /
   `remove_labels` (and `reviewer_ids` / `assignee_id` when designating), one
   `merge_request` read; compare; then `MR::ReadyForReview` + read back, only
   when every declared step succeeded.
7. **Wire.** Last line of `finalize_green_done`; `DELIVERIES` untouched (no new
   `apply_label_done` caller).
8. **Docs.** CLAUDE.md (PipelineMonitor section + configuration), CHANGELOG
   `[Unreleased]`, usage docs not touched (batch runs refresh-usage-docs).

## Tests to write (the adversary's list is appended below)

See "Would stay green" — every entry gets a named test in
`test/an_autodev_mr_reaches_its_reviewer_test.rb` (module) and
`test/review_handoff_declaration_test.rb` (declaration).
