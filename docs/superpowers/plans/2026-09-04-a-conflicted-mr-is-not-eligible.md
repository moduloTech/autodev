# A conflicted merge request is not eligible — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The review-arrears sweep stops taking somebody's ticket to re-arm a merge request that cannot merge, and the population it declines becomes visible in its report instead of silently absent.

**Architecture:** `mr_verdict` gains one question — asked only for `opened` merge requests, on the two fields `describe` already reads — and a new `:mr_conflicted` verdict that declines. A merge status GitLab has not finished computing answers `:waiting`, not `:eligible`.

**Tech Stack:** Rails 8.1.3, ActiveRecord, Minitest, RuboCop. No new gems, no new GitLab requests — both fields are already on the payload the sweep fetches.

**Spec:** `docs/superpowers/specs/2026-09-04-a-conflicted-mr-is-not-eligible-design.md`

## Global Constraints

- **TDD.** Every test verified red before its implementation, and red again with the implementation removed.
- **RuboCop green on the whole tree**: `mise x ruby -- rubocop`. Never edit any `.rubocop.yml`.
- **`CHANGELOG.md` `[Unreleased]`** updated in the same pass as the code (Task 4).
- **Conventional Commits**, types `feat` / `fix` / `refactor` / `test` / `docs` / `chore`.
- **i18n**: the sweep's report is an operator CLI report, English throughout this file and not routed through `Locales`. The new reason string follows its forty neighbours and stays an English literal — adding i18n to one line of that report would be inconsistency, not compliance. No locale file is touched by this branch.
- **Every test file must pass run on its own**: `bundle exec ruby -Itest test/services/autodev/review_arrears_sweep_test.rb` (Autodev #64).
- **Do not touch** `lib/autodev/boot_guard.rb`, `lib/autodev/supervisor.rb`, `app/services/autodev/poll_dispatcher.rb`, `app/jobs/issue_process_job.rb` or `lib/autodev/pipeline_monitor/infra_recheck.rb` — they belong to the other two branches of the alpha 54 lot.
- **No production write.** Task 1 reads the production database and writes nothing. 15839 and 14724 have already given up on their own; nothing here re-arms or cleans them.

---

## File Structure

- **Modify** `app/services/autodev/review_arrears_sweep.rb` — `mr_verdict` (`:273`), `VERDICTS` (`:126`), `MR_VERDICT_REASON` (`:135`), `report` (`:797`).
- **Modify** `test/services/autodev/review_arrears_sweep_test.rb` — one existing test is **inverted**, four are added.
- **Modify** `CHANGELOG.md`, and the error catalogue row in `CLAUDE.md` that costs `gitlab_refused_request` on this scenario.

`new_tally` (`:179`) derives its counters from `VERDICTS.values`, so adding a verdict adds its counter for free. Only `report` has to name it.

---

### Task 1: Measure what the two re-armed rows actually cost

**Files:** none — this task produces a paragraph for Task 4's changelog entry, and it can invalidate the plan's premise, which is why it is first.

**Interfaces:**
- Consumes: nothing.
- Produces: the numbers Task 4 writes down.

Point 4 of Autodev #105 asks for this, and it has already been done once — the ticket's own cost model (ninety minutes of model, ending under `gitlab_refused_request`) turned out to be wrong. Re-run it so the changelog states measured facts rather than repeating an estimate.

- [ ] **Step 1: Read the two rows**

```bash
ssh bobette-autodev.netbird.selfhosted '/usr/bin/sqlite3 -header -column ~/.autodev/autodev.db \
  "SELECT issue_iid, status, mr_iid, review_count, fix_round, discussion_fix_round, \
          needs_attention, attention_reason, datetime(finished_at) AS finished \
   FROM issues WHERE issue_iid IN (15839,14724);"'
```

Expected (as of 04/09/2026): both `done`, `needs_attention` true, 15839 under `stagnation_pipeline` finished `2026-09-04 01:10:04`, 14724 under `stagnation_discussions` finished `2026-09-04 06:02:01`.

- [ ] **Step 2: Count what they spent**

```bash
ssh bobette-autodev.netbird.selfhosted '/usr/bin/sqlite3 -header -column ~/.autodev/autodev.db \
  "SELECT i.issue_iid, json_extract(a.payload_json, \"\$.key\") AS k, COUNT(*) AS n \
   FROM activity_events a JOIN issues i ON i.id = a.issue_id \
   WHERE i.issue_iid IN (15839,14724) AND a.kind = \"danger_claude\" \
     AND a.created_at >= \"2026-09-02 15:00:00\" \
   GROUP BY i.issue_iid, k ORDER BY i.issue_iid, n DESC;"'
```

Expected shape: 15839 with 21 `discussion_fixing` and 2 `reviewing`; 14724 with 34 `discussions_checking`, 23 `discussion_unchanged` and 2 `reviewing`. **`danger_claude` is the activity-feed kind, not one model call each** — do not report the raw event count as a number of model invocations. The keys that mean a model ran are `discussion_fixing`, `reviewing`, `pipeline_fixing`.

- [ ] **Step 3: Judge the premise**

Both rows ran ~32 h and ~39 h and gave up on stagnation. Neither ended under `gitlab_refused_request`. That confirms declining: the expensive outcome is the whole correction loop running to its bound on work that cannot land, not a fast refusal.

**If the numbers say something else** — for instance that a conflicted merge request usually converges — stop and report it before writing code. The design rests on this measurement.

---

### Task 2: `mr_verdict` decides on the fields it already reads

**Files:**
- Modify: `app/services/autodev/review_arrears_sweep.rb:126` (`VERDICTS`), `:135` (`MR_VERDICT_REASON`), `:273` (`mr_verdict`)
- Modify: `test/services/autodev/review_arrears_sweep_test.rb:322` — **invert** `test_a_conflicted_merge_request_is_still_eligible`

**Interfaces:**
- Consumes: `GitlabHelpers.field(merge_req, :detailed_merge_status)` and `(…, :has_conflicts)`, already used by `describe` (`:779`) and `conflicts` (`:785`).
- Produces: the verdict symbol `:mr_conflicted`, counted as `tally[:mr_conflicted]`.

**There is an existing test asserting the defect.** `test_a_conflicted_merge_request_is_still_eligible` (`:322`) pins the current behaviour, with a comment noting the harm it causes. It is inverted, not deleted, and its comment is rewritten to say what was measured.

- [ ] **Step 1: Invert the existing test and add the new ones**

Replace `test_a_conflicted_merge_request_is_still_eligible` with:

```ruby
  # Autodev #105. This test used to assert the opposite, with a comment noting
  # that the first row a default run re-arms is the one most likely to reach a
  # danger-claude conflict resolution and a force-push on a client branch.
  #
  # Measured on 02/09/2026: two of the six eligible rows were in conflict, both
  # were taken from the people holding them, and they ran 32 and 39 hours — 21
  # danger-claude correction rounds on one of them — before giving up on
  # stagnation. Neither reached the `gitlab_refused_request` bound the ticket
  # expected. The information was on the payload the whole time: `describe` prints
  # `conflicts yes` three lines from the decision that ignores it.
  def test_a_conflicted_merge_request_is_declined
    issue = arrear

    sweep(StubClient.new(mr: FakeMr.new('opened', 'conflict', true)), apply: true)

    assert_equal 'done', issue.reload.status, 'a conflicted merge request must not be re-armed'
    assert_includes @out.string, 'conflicts'
  end

  def test_a_conflicted_merge_request_is_declined_on_the_flag_alone
    issue = arrear

    # `detailed_merge_status` can be anything while `has_conflicts` is true.
    sweep(StubClient.new(mr: FakeMr.new('opened', 'discussions_not_resolved', true)), apply: true)

    assert_equal 'done', issue.reload.status
  end

  def test_a_conflicted_merge_request_is_declined_on_the_merge_status_alone
    issue = arrear

    sweep(StubClient.new(mr: FakeMr.new('opened', 'conflict', false)), apply: true)

    assert_equal 'done', issue.reload.status
  end

  # A read that could not answer is not permission to take somebody's ticket
  # (Autodev #67, which `conflicts` already applies to this same field). `waiting`
  # costs nothing: the row stays in the arrears and the next run asks again, by
  # which time GitLab will have finished computing.
  def test_a_merge_status_still_being_computed_is_not_eligible
    issue = arrear

    sweep(StubClient.new(mr: FakeMr.new('opened', 'checking', false)), apply: true)

    assert_equal 'done', issue.reload.status
    assert_includes @out.string, 'waiting 1'
  end

  # The regression guard: this change sits on the path of every eligible row.
  def test_a_clean_merge_request_is_still_re_armed
    issue = arrear

    sweep(StubClient.new(mr: FakeMr.new('opened', 'mergeable', false)), apply: true)

    assert_equal 'checking_pipeline', issue.reload.status
  end
```

Keep `test_a_merge_status_still_being_computed_reports_unknown_conflicts` (`:332`) as it is — it asserts the *report* line, which does not change.

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec ruby -Itest test/services/autodev/review_arrears_sweep_test.rb`
Expected: FAIL on the four new decline tests — every one of them re-arms today, which is the defect.

- [ ] **Step 3: Implement**

In `app/services/autodev/review_arrears_sweep.rb`, add the verdict to `VERDICTS`:

```ruby
    VERDICTS = { eligible: :eligible, waiting: :waiting, already_merged: :already_merged,
                 mr_closed: :mr_closed, mr_conflicted: :mr_conflicted,
                 unknown_state: :unknown_state,
                 already_swept: :already_swept, not_ours: :not_ours }.freeze
```

and its sentence to `MR_VERDICT_REASON`:

```ruby
      mr_conflicted: 'the merge request has conflicts, left untouched ' \
                     '(re-arming it takes the ticket to run a correction loop on work that cannot land)',
```

Then the decision:

```ruby
    # The merge request's real state, re-read now and sorted through the one
    # definition of "does this state carry a verdict" (`MrState`, Autodev #72) —
    # `when 'locked'` written by hand is exactly the fault that ticket repaired.
    # An allow-list, never a deny-list: a state GitLab adds tomorrow is unknown
    # and nothing is done to it.
    #
    # Autodev #105 refines `opened`, and only `opened`: a merge request that
    # cannot merge is not eligible. The fields were already being read — `describe`
    # prints `conflicts yes` on the line above this decision — the decision just
    # did not look at them.
    def mr_verdict(merge_req)
      state = ::GitlabHelpers.field(merge_req, :state)
      return :waiting if ::MrState.transient?(state)

      case state
      when 'opened' then opened_verdict(merge_req)
      when 'merged' then :already_merged
      when 'closed' then :mr_closed
      else :unknown_state
      end
    end

    # `detailed_merge_status: "checking"` means GitLab has not finished computing,
    # so `has_conflicts: false` is not a fact there — the Autodev #67 rule that
    # `conflicts` already applies to this field, applied to the decision as well.
    # `:waiting` rather than `:eligible`: a read that could not answer is not
    # permission to take somebody's ticket, and the next run asks again for free.
    def opened_verdict(merge_req)
      status = ::GitlabHelpers.field(merge_req, :detailed_merge_status).to_s
      return :waiting if status == 'checking'
      return :mr_conflicted if status == 'conflict'
      return :mr_conflicted if ::GitlabHelpers.field(merge_req, :has_conflicts)

      :eligible
    end
```

And name the counter in `report` (`:797`), between `mr closed` and `unknown state`:

```ruby
          "mr closed #{tally[:mr_closed]}, conflicted #{tally[:mr_conflicted]}, " \
```

- [ ] **Step 4: Run**

Run: `bundle exec ruby -Itest test/services/autodev/review_arrears_sweep_test.rb`
Expected: PASS. If `test_the_report_carries_the_merge_request_facts` (`:312`) now fails, read why before touching it — it asserts the `describe` line, which this task does not change.

Run: `bundle exec rake test`
Expected: no regression.

- [ ] **Step 5: Prove the tests have teeth**

Change `opened_verdict` to `:eligible` unconditionally, re-run, confirm all four decline tests fail. Restore.

- [ ] **Step 6: Commit**

```bash
git add app/services/autodev/review_arrears_sweep.rb test/services/autodev/review_arrears_sweep_test.rb
git commit -m "fix: a conflicted merge request is not eligible for re-arming (Autodev #105)

mr_verdict asked the merge request one question, its state, and answered eligible
on opened. It read neither detailed_merge_status nor has_conflicts, although
describe reads and prints both three lines below — the information was there and
the decision did not look.

Measured on 02/09/2026: two of six eligible rows were in conflict, both were
taken from the people holding them (GitLab Community, one assignee), and they ran
32 and 39 hours — 21 danger-claude correction rounds on one — before giving up on
stagnation. Neither reached the gitlab_refused_request bound the ticket predicted;
the expensive outcome is the correction loop running to its bound on work that
cannot land.

A merge status GitLab has not finished computing answers waiting rather than
eligible: a read that could not answer is not permission to take somebody's
ticket, which is the Autodev #67 rule conflicts() already applies to that field."
```

---

### Task 3: The declined population is visible, and cannot be added without being counted

**Files:**
- Modify: `test/services/autodev/review_arrears_sweep_test.rb`

**Interfaces:**
- Consumes: `VERDICTS`, `MR_VERDICT_REASON`, `new_tally`, `report`.
- Produces: nothing.

Point 3 of the ticket. A declined population absent from the report is one nobody will ever act on — and `consider` (`:260`) does `MR_VERDICT_REASON.fetch(verdict)`, so a verdict added to the enum and forgotten in the reason table raises `KeyError` in front of an operator mid-run.

- [ ] **Step 1: Write the tests**

```ruby
  # --- the report is the only thing that makes a declined row actionable ------

  def test_every_verdict_that_declines_carries_a_reason
    declining = Autodev::ReviewArrearsSweep::VERDICTS.keys - [:eligible]
    documented = Autodev::ReviewArrearsSweep::MR_VERDICT_REASON.keys

    (declining & %i[waiting already_merged mr_closed mr_conflicted unknown_state]).each do |verdict|
      assert_includes documented, verdict,
                      "#{verdict} declines a row and `consider` fetches its reason — " \
                      'a missing entry is a KeyError in front of an operator'
    end
  end

  def test_every_verdict_is_named_in_the_report
    arrear
    sweep(StubClient.new(mr: FakeMr.new('opened', 'conflict', true)))

    Autodev::ReviewArrearsSweep::VERDICTS.each_key do |verdict|
      assert_includes @out.string, verdict.to_s.tr('_', ' '),
                      "#{verdict} must appear in the report, or the rows it counts are invisible"
    end
  end

  def test_the_counters_account_for_every_examined_row
    3.times { |i| arrear(iid: 900 + i) }
    sweep(StubClient.new(mr: FakeMr.new('opened', 'conflict', true)))

    assert_match(/examined 3/, @out.string)
    assert_match(/conflicted 3/, @out.string)
  end
```

`test_every_verdict_is_named_in_the_report` may need the report wording adjusted so each verdict's name is recognisable (`mr_conflicted` prints as `conflicted`). If a verdict genuinely cannot be spelled that way, relax the assertion **for that verdict by name with its reason**, never the whole loop. Check `arrear`'s real signature before passing `iid:` (`grep -n "def arrear" -A 10 test/services/autodev/review_arrears_sweep_test.rb`) and match it.

- [ ] **Step 2: Run**

Run: `bundle exec ruby -Itest test/services/autodev/review_arrears_sweep_test.rb`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add test/services/autodev/review_arrears_sweep_test.rb
git commit -m "test: every sweep verdict carries a reason and appears in the report

Autodev #105, point 3. consider fetches from MR_VERDICT_REASON, so a verdict
added to the enum and forgotten there is a KeyError mid-run; and a declined
population absent from the report is one nobody will ever act on."
```

---

### Task 4: Changelog, and the error catalogue's costing

**Files:**
- Modify: `CHANGELOG.md` (`[Unreleased]`)
- Modify: `CLAUDE.md` — the error-handling row for `gitlab_refused_request`

**Interfaces:**
- Consumes: Task 1's measurement.
- Produces: nothing.

- [ ] **Step 1: `CHANGELOG.md`**

One `### Fixed` entry under `[Unreleased]`, in the register of the existing entries. It must carry:
- the decision and why declining was free (the fields were already read for the report);
- Task 1's measurement — 32 h and 39 h, the give-up reasons, the correction-round counts — **as the correction it is**: the ticket and the error catalogue both cost this scenario at ninety minutes ending under `gitlab_refused_request`, and neither row went that way;
- the `checking` case and the Autodev #67 rule it follows;
- what is deliberately left open: a conflicted merge request stays in the arrears indefinitely, and the report counter is what makes that population visible for the next decision.

- [ ] **Step 2: `CLAUDE.md`**

Find the `gitlab_refused_request` row (`grep -n "gitlab_refused_request" CLAUDE.md`). It cites the conflicted-merge-request scenario as its costing. Add one sentence: the measured path for a re-armed conflicted merge request was the stagnation bound, not this one, so a reader is not costed against a case that did not occur. Do not rewrite the row's own subject — the bound and its ninety-minute figure are correct for the refusal loop they describe.

- [ ] **Step 3: Full gate**

Run: `bundle exec rake test`
Expected: 0 failures, 0 errors.

Run: `bundle exec ruby -Itest test/services/autodev/review_arrears_sweep_test.rb`
Expected: PASS standalone (Autodev #64).

Run: `mise x ruby -- rubocop`
Expected: no offenses, whole tree.

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md CLAUDE.md
git commit -m "docs: record the conflicted-MR decline and correct its costing

Autodev #105. The ticket and the error catalogue both cost this scenario at
ninety minutes ending under gitlab_refused_request; the two rows measured on
02/09 ran 32 and 39 hours and gave up on stagnation instead."
```

---

## Definition of done

- `bundle exec rake test` green; the sweep's test file green standalone.
- `mise x ruby -- rubocop` clean on the whole tree.
- A conflicted merge request is declined on either signal, and a clean one is still re-armed.
- `detailed_merge_status: "checking"` answers `waiting`, not `eligible`.
- `:mr_conflicted` appears in `VERDICTS`, in `MR_VERDICT_REASON` and in the report line, with a test that a future verdict cannot skip any of the three.
- The existing `test_a_conflicted_merge_request_is_still_eligible` is inverted, not deleted, and its comment says what was measured.
- `CHANGELOG.md` `[Unreleased]` carries the fix and the corrected cost model; the `gitlab_refused_request` row in `CLAUDE.md` no longer costs a reader against a path that did not occur.
- No production write.
