# Plan: a network cut is not a fix failure (Autodev #125)

Spec: `docs/superpowers/specs/2026-09-28-a-network-cut-is-not-a-fix-failure-design.md`.
Revised after the plan adversary, whose findings are the tests listed below.

Test: `mise x ruby@4.0.1 -- bundle exec rake test` (baseline: 2777 runs, 0 failures).
One file: `mise x ruby@4.0.1 -- bundle exec ruby -Itest test/<file>_test.rb`. Every
new file must pass when run alone (CLAUDE.md, Tests).
Lint: `mise x ruby@4.0.1 -- bundle exec rubocop <files>`.

## Frozen contract

- **The transport family.** Every new clause spells it out, as in
  `app/services/autodev/external_state.rb:142`, and never as a `*TRANSPORT_ERRORS`
  splat:
  `::Gitlab::Error::ResponseError, ::SystemCallError, ::Timeout::Error, ::SocketError, ::OpenSSL::SSL::SSLError, ::EOFError`.
- **A read** converts with `GitlabHelpers.answer(:issue_links) { … }` or
  `answer(:job_trace)`. It keeps its HTTP behaviour through
  `rescue ApiUnavailableError => e`, then `raise unless e.cause.is_a?(::Gitlab::Error::ResponseError)`.
- **`IssueNotifier#after_conclusion(what)`** takes a block. It runs the block,
  swallows the family and logs `"… #{what} …: #{e.class}: #{e.message}"` through
  `log_error`. It returns the block's value, or `nil` on a swallow.
- **`MrFixer#resolve_discussion(mr_iid, discussion_id)`** returns `true` when the
  thread was resolved and `false` otherwise.
- **`BacktraceExcerpt`** is a plain top-level module in
  `lib/autodev/backtrace_excerpt.rb`, required from `lib/autodev.rb` before
  `gitlab_request_counter`:
  - `ROOT = File.expand_path('../..', __dir__)`, `HEAD = 10`, `OWN = 10`;
  - `own_frame?(line)`: true for `ROOT + '/'` and false under `ROOT/vendor/`;
  - `lines(error)`: `backtrace.first(HEAD)`, followed by the first `OWN` own
    frames of the backtrace that are not already in the head, in backtrace
    order. It returns `[]` when the backtrace is nil;
  - `format(error)`: `lines(error).join("\n  ")`, or nil when that is empty;
  - `first_own_location(locations, skip:)`: the `to_s` of the first location that
    is own and whose path is not in `skip`.
- **The dormant pair** is reset with `dormant_recheck_count: 0, dormant_recheck_at: nil`.

## Lane A: transport at the call sites

Files:
- `lib/autodev/gitlab_helpers.rb` (`IssueFormatter.append_links`)
- `lib/autodev/mr_fixer.rb` (`resolve_discussion`)
- `lib/autodev/mr_fixer/fix_cycle.rb` (`fix_single_discussion`, `report_round`)
- `lib/autodev/issue_notifier.rb` (`after_conclusion` is new; `hand_ticket_back`)
- `lib/autodev/issue_abandonment.rb` (`abandon_issue`)
- `lib/autodev/pipeline_monitor/api_helpers.rb` (`fetch_job_trace`)
- `lib/autodev/pipeline_monitor/failure_handler.rb` (`retrigger_if_needed`)
- `lib/autodev/pipeline_monitor/pipeline_fixer.rb` (`notify_fix_pushed`)
- `test/api_failure_is_not_a_verdict_test.rb`: only the ALLOWED_SWALLOWS
  sentences and the entries themselves
- a new file, `test/a_network_cut_is_not_a_fix_failure_test.rb`

Do **not** change `notify_issue`, `assign_to_self` or `LabelManager`.

Tests. Each one must fail before the change, except those marked "control":

1. **MrFixer round, `issue_links` cut.** The fake client's `issue_links` raises
   `Net::OpenTimeout`. The row stays `fixing_discussions`, and nothing is written:
   no `mr_fix_error` note, no `error_message`, `fix_round` unchanged. A second
   round with a healthy client runs the fix, which is the replay. The error's
   `what` is `:issue_links`.
2. **`resolve_merge_request_discussion` cut.** Two verified threads, and the
   resolution of one of them raises `Net::OpenTimeout`. The round completes and
   the row reaches `checking_pipeline`, with no error note. The success notice
   carries `count: 1`.
3. **MrFixer post-push notice cut.** `create_issue_note` for `mr_fix_success`
   raises `Net::OpenTimeout`. The row is `checking_pipeline`, not `error`.
4. **PipelineFixer, `issue_links` cut.** The `ApiUnavailableError` reaches
   `PipelineMonitor#check`'s boundary and the row is not `error`. It is back
   where `check` leaves it, so assert the actual state, not a guess. No
   `pipeline_fix_error` note is posted.
5. **PipelineFixer post-push notice cut.** The row went through
   `pipeline_fix_done!` and is `checking_pipeline`, not `error`.
6. **`job_trace`.** A `Net::ReadTimeout` raises `ApiUnavailableError` with
   `what == :job_trace`. A 404 `Gitlab::Error::NotFound` gives exactly
   `"(trace unavailable: #{not_found.message})"`, with `refute_match(/did not answer/)`.
7. **`append_links` still swallows the capability gap.** A 404 gives no "Related
   issues" section and no raise. So does a client without `issue_links`, and so
   does a client whose `issue_links` raises `NoMethodError`.
8. **`retrigger_if_needed`.** Triage `:uncertain`, `pipeline_retrigger_count: 0`,
   and `retry_pipeline` raises `Net::ReadTimeout`. It returns `false`, the count
   stays at 0, and the triage continues: spy on `infra_skip?` or `claude_available?`.
9. **`hand_ticket_back`.** `edit_issue` raises `Net::OpenTimeout`, then
   `Errno::ECONNREFUSED`, and each gives `assert_same false`. Then a real
   `abandon_issue` on that client: the notice is posted without the
   `abandon_reassigned` suffix.
10. **The whole family, table-driven.** Over `resolve_discussion`,
    `hand_ticket_back`, `retrigger_if_needed` and `after_conclusion`, raise each of
    `Errno::ECONNRESET`, `Errno::EHOSTUNREACH`, `Errno::ECONNREFUSED`,
    `Net::OpenTimeout`, `Net::ReadTimeout`, `SocketError`,
    `OpenSSL::SSL::SSLError` and `EOFError`. None raises, and each returns its
    contracted value. `NoMethodError` still propagates from each.
11. **Controls.**
    - A genuine fix failure: danger-claude raises `ImplementationError`, or the
      push fails. It still ends in `error` with the `mr_fix_error` note.
    - `clone_and_checkout` raises `Errno::ENOENT`. It ends in `error` +
      `mr_fix_error`, never in an `ApiUnavailableError`. Do the same for the
      pipeline path (`pipeline_fix_error`).
    - `QuestionHandler#post_answer` with `create_issue_note` raising
      `Net::OpenTimeout`. The error still propagates, and `question_answered!` is
      not fired.
12. **`abandon_issue` after `abandon!`.** A cut on the label write or on the
    notice leaves the row `done` + `needs_attention`, and nothing raises.

## Lane B: the diagnostics

Files:
- a new `lib/autodev/backtrace_excerpt.rb`
- `lib/autodev.rb` (one require)
- `lib/autodev/mr_fixer/error_handler.rb`
- `lib/autodev/pipeline_monitor/error_handler.rb`
- `lib/autodev/issue_processor/error_handler.rb`
- `lib/autodev/gitlab_request_counter.rb`
- a new `test/backtrace_excerpt_test.rb`
- `test/gitlab_request_counter_test.rb`

Tests:

1. **Head plus the next own frames.** The head is 5 own frames and 5 gem frames,
   followed by 15 numbered own frames. `lines` must equal exactly the head
   followed by the first 10 of those 15, checked with `assert_equal` on the
   whole array. A backtrace with no own frame outside the head gives the head
   alone. A nil backtrace gives `[]`.
2. **`own_frame?`.** It is true for `"#{ROOT}/lib/x.rb:1"`. It is false for
   `"#{ROOT}-other/lib/x.rb:1"`, for `"#{ROOT}/vendor/bundle/…"`, and for a gem
   path outside ROOT.
3. **The three handlers.** For `handle_fix_error`, `handle_failure_error` and
   `handle_process_error`, build a forged backtrace with `set_backtrace`: 12
   `…/gems/net-http-0.9.1/…` frames, then
   `"#{ROOT}/lib/autodev/mr_fixer.rb:150:in 'resolve_discussion'"`. Assert that
   `error_message` includes `lib/autodev/mr_fixer.rb:150`. This must fail with
   `first(10)`. With a spy logger, a logged line contains that frame too.
4. **`caller_location` through pagination.**
   `GitlabPagesClient.new(pages, fail_on_page: 2, error: Net::ReadTimeout.new)`
   comes from `test/gitlab_pages.rb` and is wrapped in `GitlabRequestCounter`.
   The test calls `.issue_label_events(...).auto_paginate`. The recorded
   `GitlabTransportFailure#caller_location` ends on the test file's line, not on
   the counter's file or the gem's. Also test a direct call.

## Lane C: the dormant budget

Files:
- `lib/autodev/poll_router/resume_handler.rb`
- `app/models/issue.rb`
- a new `test/a_resume_restores_the_dormant_budget_test.rb`

Tests:

1. **The A#139 replay.** Take a scope holding one row with `mr_iid` and one
   without, both with `dormant_recheck_count: 3` and
   `dormant_recheck_at: 1.day.from_now`. Call
   `Issue.reset_for_retry!(scope, reset_budget: true)`: both rows end at
   `(0, nil)`. Put both back in dormant `error`: `DormantAudit#candidates`
   includes both.
2. **`reset_for_retry!` without `reset_budget`** leaves the pair untouched.
3. **The human paths reset the pair.** `reenter_via_reimplementation` does, and
   so does `reenter_via_pipeline_check` with `origin: nil`.
4. **The automatic paths do not.** `resume_recovered_infra` on a row with
   `dormant_recheck_count: 2` keeps it at 2 (it passes no origin — the trigger cannot be `origin`). So does `ReviewArrearsSweep`'s resume.
5. **No reset on revive.** Take the `dormant_audit_routing_test.rb:172` case
   (`implementing`, `mr_iid: nil`, 4 h) and its `mr_iid: 42` variant: after
   `audit`, `dormant_recheck_count == 1`.

## Me, after integration

- CHANGELOG `[Unreleased]`
- CLAUDE.md (Error Handling, and the "Writes are a separate case" sentence)
- the full suite and RuboCop on the whole tree
- sabotage
- three reviews

## Amendment 1 (2026-09-29): resolutions after the push, and remembered

The adversarial review reproduced a blocker, with a harness in the scratchpad.
A thread was verified, then its resolution was cut. That thread can never be
resolved:
- the next round finds its correction already on the branch, so the diff is
  empty and the verdict is `:unchanged`;
- after `stagnation_threshold` rounds, the row ends in `stagnation_discussions`.

A second defect predates this branch: resolutions were made **before** the push,
so a round that aborts after a resolution leaves a thread resolved whose
correction was never pushed.

Owner's decision (2026-09-29): resolve after the push, and remember a
resolution that did not take.

Frozen contract:
- **The column.** A new migration adds `issues.pending_resolutions` (`:text`,
  `if_not_exists: true`, as in `db/migrate/20260923000001_…`). It holds a JSON
  object `{ "<discussion_id>" => "<ISO8601 UTC time the verdict was reached>" }`,
  and NULL means empty.
- **`fix_single_discussion`** does not resolve any more. It returns the
  discussion when the verdict is `addressed` (or `FixCheck.passed`), and nil
  otherwise.
- **`run_fix_cycle`** resolves the attempted-and-addressed threads **after**
  `push_fixes`, or directly when there are no new commits
  (`finalize_no_commits`), through `resolve_discussion` (true/false).
  - Resolved threads are counted.
  - A thread whose resolution did not take is recorded in `pending_resolutions`
    with the time of its verdict.
  - It also gets one activity entry, `discussion_resolution_deferred`, with the
    thread title. The wording is fr+en in `config/locales/activity.*.yml`, and
    must say the correction was validated and pushed but GitLab did not take
    the resolution, so the next round will resolve it without re-fixing.
- **`report_round`.** When `count` is 0 and at least one resolution was
  deferred, it must not write `discussions_none_resolved`, which would be false.
  It writes nothing more at round level, because the per-thread entries already
  say it. When `count` is positive, the success notice counts only resolved
  threads, as before.
- **At the start of a round**, in `process_discussions` before the empty check,
  a pending id is handled against the unresolved threads GitLab returns:
  - The id is among them, and **no note on that discussion is newer than the
    recorded time**: resolve it directly, with no fix and no verification.
    - If that succeeds, drop it from the list this round will fix, and drop it
      from pending.
    - If it fails, keep it in pending, and leave it out of this round's fix
      list, because the correction is already on the branch.
  - The id is among them, but a note is newer than the recorded time (a human
    replied): drop it from pending, and let the round fix it normally.
  - The id is not among them: it is resolved or gone, so drop it from pending.

  Persist the column once. If nothing is left to fix, the existing
  `transition_no_discussions` path applies.
- **Clearing.** `ResumeHandler#reenter_via_reimplementation` clears the column,
  because the branch is rebuilt.
- **`retrigger_if_needed`.** A non-HTTP transport failure (the family minus
  `Gitlab::Error::ResponseError`) may have reached GitLab, since a
  `Net::ReadTimeout` comes after the request was sent. So it is counted as a
  retrigger: advance `pipeline_retrigger_count`, log it, and return `true` (wait
  for the next poll). An HTTP `ResponseError` is GitLab's refusal, so it keeps
  answering `false`. The truthfulness review found that the old comment ("false
  says the pipeline was not retriggered, which is what happened") is not
  established for a timeout.
- **Comments.** On `resolve_discussion` and `hand_ticket_back`, the comment
  says that a timeout may have landed, and that `false` errs in the safe
  direction (an undercount, a handback left unclaimed).
- **Cosmetic.** The `app/models/issue.rb` comment above `reset_for_retry!`
  still says "zeroes `retry_count` and `review_failure_count`" and must name
  all four fields. Its new paragraph must also name `recover_errored!`, which
  calls the method without the budget flag as well.

Tests (red before, where they apply):
- **The blocker replay.** Adapt the adversarial probe (`MrFixRoundHarness`,
  verification on). Two threads, and t2's resolution is cut. Round 2 has GitLab
  returning [t2], an empty diff and no new commits. t2 is resolved at the start
  of round 2 without any danger-claude call, the row reaches `checking_pipeline`,
  and no `stagnation_discussions` follows.
- **A human replied after the verdict.** Same setup, but t2 carries a note newer
  than the recorded time: it is fixed normally, not auto-resolved.
- **Resolution comes after the push.** When the push fails, no thread was
  resolved (`client.resolved == []`) and the row is `error`, which is unchanged.
- **The single-thread case.** The only thread's resolution is cut: the activity
  shows `discussion_resolution_deferred`, and no `discussions_none_resolved`.
- **A retrigger `Net::ReadTimeout`** returns `true` and the count is 1. A 500
  `ResponseError` returns `false` and the count is 0. Replace the old test 8
  expectation.
- **Reimplementation** clears `pending_resolutions`.
- **The sabotage gap.** `test_an_issue_links_cut_leaves_the_row_on_the_watch`
  must also assert that no fix was attempted: `fix_round` is 0, there is no
  `:pipeline_fix_pushed`, and there was no danger-claude call.
