# Plan — the spec check blocks an undescribed decision (Autodev #122)

Spec: `docs/superpowers/specs/2026-10-08-the-spec-check-blocks-an-undescribed-decision-design.md`.

One lane: the change is a prompt, one keyword argument, one boot warning, one
form hint and their locale keys — below the two-lane threshold, so it is
implemented in this session, TDD.

## Frozen contract

- `IssueProcessor::Prompts::SPEC_CHECK` — rewritten (French, like the other
  prompts). Same `%s` placeholder, same JSON answer shape
  (`{"type": "implementation"|"question"|"unclear", "issues": [...]}`), so
  `SpecChecker#parse_spec_result` is unchanged. Adds three blocking criteria:
  (1) the description contradicts a later answer in the comments; (2) a decision
  is taken but what it implies (screen/place, access, output, replace vs add) is
  not described; (3) an answer to a previous clarification changes the nature of
  the request → `implementation` only once (2) is satisfied. Keeps the
  pragmatism rule for truly minor details.
- `SpecChecker#check_specification` calls `danger_claude_prompt(work_dir, prompt)`
  with **no** `model:` — Claude Code's default model unless the deprecated
  `model` setting is set.
- `Config::DEPRECATED_MODEL_SETTINGS = %w[model effort].freeze`.
- `Config.deprecated_model_settings(config, project_configs)` →
  `Array<{ scope: 'global' | <project path>, field: String, value: }>`, globals
  first, then projects in the order given; blank values (`nil`, `''`) are not a
  setting and are not reported.
- `bin/autodev`: `warn_deprecated_model_settings(config, logger, pastel)` called
  in `bootstrap` after `warn_rejected_numeric_settings`; rescues `StandardError`
  (it reads the `projects` table through `Project.runtime_configs`), and
  `warn_model_setting_deprecations(found, config, logger, pastel)` prints a bold
  header plus one line per setting.
- Locale keys (fr + en): `cli_model_settings_deprecated_header` (`%{count}`),
  `cli_model_settings_deprecated_global` (`%{field}`, `%{value}`),
  `cli_model_settings_deprecated_project` (`%{project}`, `%{field}`, `%{value}`),
  `web_project_edit_deprecated_setting`.
- `Web::Views::ProjectEdit#field_hint` appends `web_project_edit_deprecated_setting`
  for the keys in `Config::DEPRECATED_MODEL_SETTINGS`, and only those.
- `DangerClaudeRunner#dc_global_args` is **not** changed: project > global >
  per-call default, as before. Deprecated means "still read, signalled".

## Tests (TDD — red first, then green)

| File | Holds |
|---|---|
| `test/the_spec_check_runs_on_the_default_model_test.rb` | the args reaching `run_with_timeout` carry no `-m` when nothing is configured; a global `model` / project `model` / `effort` still reach `-m` / `-e` (precedence project > global) |
| `test/spec_check_verdict_test.rb` | `check_specification` driven end to end with a stubbed `danger_claude_prompt`: `implementation` → `implementing`, returns false; `question` → `answering_question` path, returns true; `unclear` + issues → `needs_clarification` and the issues posted numbered, returns true; `unclear` + `[]` → `implementing`; prose around the JSON; a JSON fenced in markdown; unparsable output → `implementing`; legacy `{"clear": false, "issues": [...]}` → parked; legacy `{"clear": true}` → `implementing` |
| `test/spec_check_prompt_test.rb` | `SPEC_CHECK` names the three blocking criteria and keeps the pragmatism rule; formats with one `%s` |
| `test/model_settings_deprecation_test.rb` | `Config.deprecated_model_settings` (global, project, blank ignored, order); the boot warning (silent when none, names global and project settings and values, fr/en, header count, a raising `Project.runtime_configs` is swallowed) |
| `test/components/web/project_edit_deprecation_test.rb` (or the existing edit controller test) | the notice is rendered under `model` and `effort`, and not under another field |

## Docs

- `CHANGELOG.md` `[Unreleased]`.
- `CLAUDE.md`: a sentence on the spec check's model and on the deprecation.
- `docs/usage/autodev-technical-usage.md` rows for `model` / `effort` marked
  deprecated.
