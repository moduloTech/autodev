# Plan — pre-existing target failures (Autodev #130)

Spec: `docs/superpowers/specs/2026-10-08-preexisting-target-failures-design.md`.

One lane, implemented in this session: the change is one module of the pipeline
monitor plus its locale keys, and every file it touches is on the same call path
(`triage_and_fix` → the new module → `WatchBound`). Splitting it would give two
agents the same three files.

## Files

| File | Change |
|---|---|
| `db/migrate/20261008130001_add_target_red_columns_to_issues.rb` | new: `target_red_hold_pipeline_id` integer, `preexisting_noted_key` string, `if_not_exists` |
| `lib/autodev/pipeline_monitor/failure_signature.rb` | new, pure functions |
| `lib/autodev/pipeline_monitor/preexisting_failures.rb` | new mixin: split, announce, hold, retry |
| `lib/autodev/pipeline_monitor/failure_handler.rb` | `triage_and_fix` calls `set_aside_preexisting` before `check_stagnation_and_fix` |
| `lib/autodev/pipeline_monitor/watch_bound.rb` | `give_up_on_watch` uses `target_pipeline_red` when this poll held |
| `lib/autodev/pipeline_monitor.rb` | require + include; `poll_open_mr` keeps the merge request for the poll (`@polled_mr`), `begin_poll` clears it and the hold flag |
| `config/locales/{activity,notifications,web}.{fr,en}.yml` | the six keys |
| `test/api_failure_is_not_a_verdict_test.rb` | declare the trace read's HTTP-answer exemption if the guard asks |
| `CHANGELOG.md`, `CLAUDE.md` | documentation |

## Tests (`test/a_red_target_is_not_fixed_in_the_mr_test.rb`, `test/pipeline_monitor/failure_signature_test.rb`)

Driven through `PipelineMonitor#check`, with a fake client serving the merge
request (with `target_branch`), its pipeline, the target's pipelines, both job
lists and both traces — the harness of `stagnation_counts_attempts_test.rb`.

1. Only red job pre-existing (same name, same examples) → no fixer, no Claude, no
   stagnation count, row stays `checking_pipeline`, hold recorded, activity line
   and one MR note naming job + target pipeline.
2. Same, polled again → still one MR note.
3. Same job red on the target for a **different** reason (target tail is a git
   error, MR has failed examples) → fixed as today, stagnation counted.
4. Job green on the target → fixed as today.
5. Two red jobs, one pre-existing → only the other reaches the fixer; the
   stagnation signature is that of the other alone.
6. Held, then the target's latest finished pipeline goes green → `retry_pipeline`
   on the held pipeline, hold cleared, no fixer that poll.
7. Held past `pipeline_watch_max_days` → `done`, `target_pipeline_red`, comment
   naming the job, target branch and pipeline; not `pipeline_watch_expired`.
8. Expired watch on a poll that did **not** hold (stale hold column from an older
   pipeline) → `pipeline_watch_expired`.
9. Target pipelines read fails → poll aborts, row untouched, no fixer.
10. MR names no target branch → today's behaviour.
11. Truncated trace on either side → own.
12. Target pipeline still running is skipped; the latest *finished* one decides
    (`manual` counts as finished).
13. Target job `allow_failure: true` failed → not pre-existing.

`FailureSignature` unit tests: prefix/ANSI stripping, section cut, examples
subset vs superset, tail equality with digits/hex normalised, runner warnings
ignored, empty and truncated traces → nil, mixed kinds never comparable.

Locale tests come for free from `test/i18n_derived_keys_test.rb` and
`test/locales_test.rb`.
