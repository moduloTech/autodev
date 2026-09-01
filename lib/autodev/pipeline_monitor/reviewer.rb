# frozen_string_literal: true

require 'tmpdir'

class PipelineMonitor
  # Runs mr-review on the MR after a green pipeline.
  # Manages review_count and transitions via review_done!.
  #
  # `Metrics/ModuleLength` is disabled for the same reason `MrFixer::FixCycle`
  # disables it: this module holds two cohesive halves that only a metric wants
  # apart — the review lifecycle (which path, which of the three outcomes, the
  # failure budget, the give-up) and the `mr-review` binary's own invocation plus
  # the failure diagnostic Autodev #49 added. Splitting the diagnostic out would put
  # `DIAGNOSTIC_STREAM_LIMIT` in one file and its only reader in another.
  module Reviewer # rubocop:disable Metrics/ModuleLength
    MAX_REVIEW_ROUNDS = 3
    # Consecutive mr-review failures before we give up reviewing the MR. Each
    # failed mr-review still fires a state transition, so without a cap the
    # checking_pipeline ↔ reviewing loop runs forever on a persistently
    # broken mr-review (token expired, binary crash, etc.).
    REVIEW_FAILURE_THRESHOLD = 5
    # Per stream, in the failure message only (Autodev #49). 300 characters — the
    # previous cap, applied to stderr alone — is about four lines, enough to lose
    # the actual error inside a usage dump. Truncation is announced rather than
    # silent, so a log line can ask for a bigger cap instead of hiding the need
    # for one. The head is kept, not the tail: Ruby prints the exception line
    # first and OptionParser prints usage first, which are the two shapes this
    # failure is expected to take.
    DIAGNOSTIC_STREAM_LIMIT = 2000

    private

    # `.presence`, not truthiness: `''` is truthy in Ruby, so a YAML-only project
    # spelling `review_skill:` with an empty value took the skill path with an
    # empty skill name — a clone, a danger-claude run and a prompt naming no skill
    # at all. A blank reads as absent.
    #
    # The three rescues below all answer the same question: `green_first_review`
    # fires `pipeline_green!` *before* calling in here, so the row is already in
    # `reviewing`, and `dispatch_pipelines` selects `checking_pipeline` only.
    # Anything that escapes this method parks the row where no dispatch pass will
    # re-read it, leaving recovery to `DormantAudit` two hours later at the cost of
    # one of three `dormant_audit_max` attempts. On the binary path nothing
    # escapes — `execute_mr_review` rescues `StandardError` — which is why the
    # skill path needed these.
    #
    # A bare `ConfigError` is deliberately still not among them and keeps escaping:
    # see the error catalogue in CLAUDE.md. Rescuing it *and resuming the watch*
    # would write an activity row every poll, which keeps the row out of
    # `DormantAudit`'s active arm forever *and* restarts the age clock — an
    # unbounded, unsignalled loop, strictly worse than parking.
    #
    # Its one named member is the exception (Autodev #81), and the reason the
    # trap above does not apply to it is that the row does not come back: see
    # `give_up_on_missing_review_skill`.
    def launch_review(issue)
      skill = @project_config['review_skill'].presence
      announce_review(issue, skill)
      dispatch_review_outcome(issue, skill ? review_with_skill(issue) : execute_mr_review(issue))
    # A GitLab outage while *we* publish is not a review failure and must not spend
    # the budget (Autodev #62, #71) — so neither counter is touched — but the row
    # still has to come back to `checking_pipeline` before the poll aborts at
    # `PipelineMonitor#check`'s boundary, or nothing re-enqueues it. Re-raised so
    # the abort still happens and `abandon_expired_watch` stays unreached.
    # The project declared a review skill its repository does not carry. Nothing
    # further can be attempted for this request, or for any other request of the
    # project, until somebody fixes the configuration or adds the skill — so the
    # answer is a give-up that says so, not a retry (Autodev #81).
    rescue MissingReviewSkillError => e
      give_up_on_missing_review_skill(issue, e)
    rescue ApiUnavailableError
      resume_watch(issue)
      raise
    # `check_dc_failures!` runs inside `danger_claude_prompt`, so the skill path can
    # raise these two where the binary path never could. `handle_review_interruption`
    # (ErrorHandler) sorts them the way every other `danger_claude_prompt` call site
    # does — `handle_rate_limit` for the quota, `handle_auth_failure` for dead
    # credentials. Named here because this path has no generic handler by design (a
    # `StandardError` from the review is already `false`), so neither class would be
    # caught otherwise.
    rescue RateLimitError, AuthenticationError => e
      handle_review_interruption(issue, e)
    end

    # Which path is about to run, on both sinks. Split out of `launch_review` so
    # that method reads as what it is — one call and the four ways it can end.
    def announce_review(issue, skill)
      log "Launching review for MR !#{issue.mr_iid} " \
          "(#{skill ? "skill '#{skill}'" : 'mr-review binary'}, review_count: #{issue.review_count})"
      log_activity(issue, :reviewing)
    end

    # Three outcomes, not two. `:inconclusive` means GitLab had not computed the
    # MR's diff_refs yet, so nothing could be published: hand the row back to
    # `checking_pipeline` WITHOUT touching either counter, and the next cycle runs
    # the whole review again (review_count is still 0). Counting it as a success
    # would deliver the MR unreviewed; counting it as a failure would spend a
    # budget on a cycle that could not act (Autodev #71).
    def dispatch_review_outcome(issue, outcome)
      return finalize_review_success(issue) if outcome == true
      return finalize_review_failure(issue) unless outcome == :inconclusive

      log "MR !#{issue.mr_iid}: review not published this cycle, retrying next poll"
      resume_watch(issue)
    end

    # The two ways the row goes back to the watch having done nothing: an
    # `:inconclusive` review and a GitLab outage while publishing. Neither counter
    # moves, so the row did not move either — and `review_done!` would otherwise
    # restamp `checking_pipeline_since` to now on the way in, restarting the age
    # bound on every poll (Autodev #74). `restore_watch_clock` puts the age this
    # poll started with back.
    def resume_watch(issue)
      issue.review_done!
      restore_watch_clock(issue)
    end

    def finalize_review_success(issue)
      increment_review_count(issue)
      reset_review_failure_count(issue)
      DiscussionSnapshot.capture(context: :post_mr_review, client: @client, project_path: @project_path,
                                 mr_iid: issue.mr_iid, logger: @logger, issue: issue)
      issue.review_done!
      log_activity(issue, :review_done)
    end

    def finalize_review_failure(issue)
      new_failures = (issue.review_failure_count || 0) + 1
      Issue.where(id: issue.id).update(review_failure_count: new_failures)
      issue.review_failure_count = new_failures
      log "review failed (consecutive failures: #{new_failures}/#{REVIEW_FAILURE_THRESHOLD})"
      return give_up_reviewing(issue) if new_failures >= REVIEW_FAILURE_THRESHOLD

      issue.review_done!
      log_activity(issue, :review_failed, count: new_failures)
    end

    # The fifth give-up path. It keeps its own AASM event (`review_giveup` — it is
    # the only one that starts from `reviewing`), but it poses the same end label
    # as the four that go through `IssueAbandonment#abandon_issue`:
    # `label_attention`, never `label_done` (Autodev #63). This is the path the
    # ticket was filed against — `label_done` reads "ready for feature review" on
    # the projects concerned, and autodev had just failed to review the MR five
    # times in a row.
    def give_up_reviewing(issue)
      issue.review_giveup!
      apply_label_attention(issue.issue_iid)
      reassign_to_author(issue)
      # The diagnostic outlives log rotation, in the same columns every other
      # failure in the product uses (Autodev #49), and the issue detail page
      # renders them for exactly this shape of row — `done` + `needs_attention`
      # (Autodev #59). Scrubbed on the way into the buffers by
      # ProcessRunner#record_output, not here: fourteen sites persist them.
      Issue.where(id: issue.id).update_all(finished_at: Time.current, needs_attention: true,
                                           attention_reason: 'review_failures_exhausted',
                                           dc_stdout: @dc_stdout, dc_stderr: @dc_stderr)
      notify_localized(issue.issue_iid, :review_failures_exhausted,
                       mr_url: issue.mr_url, count: REVIEW_FAILURE_THRESHOLD)
      log_activity(issue, :review_failures_exhausted, count: REVIEW_FAILURE_THRESHOLD)
      log "Issue ##{issue.issue_iid}: #{REVIEW_FAILURE_THRESHOLD} consecutive review failures → done"
    end

    # The sixth give-up path, and the answer to Autodev #81 (the ticket's option
    # 1): a `review_skill` whose `SKILL.md` is not in the clone.
    #
    # Two things have to be true at once, and only one of them was available to
    # Autodev #74. **The cause is named**: `review_skill_missing` reaches the
    # operator through all three sinks the abandon point drives — the GitLab
    # comment, the activity line and the `/errors` + health-card explanation —
    # instead of the request surfacing five hours later as a generic
    # `dormant_exhausted`, with the real message only in the log. And **the line
    # stops**: `abandon` takes the row to `done`, which `dispatch_pipelines` does
    # not select, which `dispatch_done_unassigned` excludes because the row is
    # flagged, and which `dispatch_infra_recheck` excludes because the reason is
    # not `stagnation_pipeline`.
    #
    # That second half is not a nicety, it is what makes rescuing this safe at
    # all. Rescuing and resuming the watch — the obvious shape — writes an
    # activity row on every poll, so `Issue.without_activity_since` never reads
    # the row as dormant and `DormantAudit`'s active arm never sees it again,
    # while every return to `checking_pipeline` restamps
    # `checking_pipeline_since` and stands the age bound back up. That is an
    # unbounded, unsignalled loop, and it is why Autodev #74 preferred to let the
    # error escape. A give-up has neither property because the row never comes
    # back.
    #
    # No `detail:`. It lands on `attention_detail`, which renders verbatim
    # through `web_errors_attention_detail` ("Job(s) en cause : …"), so it may
    # only carry a failing job name; the skill and its expected path travel as
    # ordinary template vars to the two sinks that can phrase them.
    def give_up_on_missing_review_skill(issue, error)
      log_error "Issue ##{issue.issue_iid}: #{error.message}"
      abandon_issue(issue, :review_skill_missing, skill: error.skill, path: error.relative_path)
    end

    def reset_review_failure_count(issue)
      return if (issue.review_failure_count || 0).zero?

      Issue.where(id: issue.id).update(review_failure_count: 0)
      issue.review_failure_count = 0
    end

    def execute_mr_review(issue)
      return log('mr-review not installed, skipping review') && false unless command_exists?('mr-review')

      log 'Waiting 15s for GitLab to compute diff_refs...'
      sleep 15
      run_mr_review_command(issue.mr_url)
    rescue StandardError => e
      log_error "mr-review error (non-fatal): #{e.message}"
      false
    end

    # mr-review is not a danger-claude call, so it gets no heartbeat of its own
    # from DangerClaudeRunner — hence the explicit marker (Autodev #50), written
    # before the call so the clock starts as late as possible.
    #
    # It runs under run_with_timeout rather than a raw Open3 (Autodev #54): the
    # cap is `mr_review_timeout` (a per-project override, else
    # Config::MR_REVIEW_TIMEOUT), which HealthReport#longest_worker_timeout
    # already folds into the stuck-window, so `reviewing` stops being an
    # exception the window cannot size. On timeout the wrapper raises
    # ImplementationError, which execute_mr_review's rescue turns into `false`
    # — a review failure counted by launch_review, not a failed request.
    #
    # chdir: is Dir.tmpdir — neutral, declared, and always present (Autodev #77).
    # It used to be Dir.pwd, "keeping the previous behaviour" of the Open3.capture3
    # era: whatever cwd the worker happened to have (in production
    # `/Users/modulotech`, the launchd plist's WorkingDirectory). That was an
    # absence of decision, and it is what made #77's original diagnosis — that
    # mr-review reads autodev's own CLAUDE.md as the project's conventions —
    # plausible on reading.
    #
    # The directory is indifferent because mr-review sits in none of it: it clones
    # the MR's source branch itself (/tmp/mr-review_<mr_iid>_<pid>) and runs every
    # command it delegates with `chdir:` into that clone — which is the "repo root"
    # its review prompt means when it asks for CLAUDE.md — and every other path it
    # touches is absolute (~/.mr-review/mr-review.db, its tempfiles). All that is
    # required of the value is that it exist: Process.spawn fails outright
    # otherwise, and a review failure is what that would look like.
    #
    # Both streams and the exit status are reported on failure (Autodev #49).
    # Keeping stderr alone made every production failure log the same empty line,
    # because mr-review writes nothing there.
    def run_mr_review_command(mr_url)
      log "Running mr-review on #{mr_url}..."
      dc_heartbeat!('mr-review')
      out, err, ok, status = run_with_timeout(
        'mr-review', ['-H', mr_url],
        chdir: Dir.tmpdir, timeout: mr_review_timeout, env: mr_review_env
      )
      return log('Review completed successfully') || true if ok

      log_error "mr-review failed (non-fatal): #{review_failure_diagnostic(out, err, status)}"
      false
    end

    # The GitLab credential `mr-review` authenticates with, handed over by autodev
    # instead of left to the binary's own `~/.mr-review/config.yml` (Autodev #80).
    #
    # That file is how four months of silence happened: it lives in another tool's
    # directory, it was last written on 14 April 2026, and the token in it was
    # revoked that same month. Nothing in autodev's chain exported
    # GITLAB_API_TOKEN — not the launchd plist, not a shell profile — so mr-review
    # fell through to the file and every review through the binary failed with
    # `401 Token was revoked`. Exporting it here makes autodev's configuration the
    # one place a review credential is declared, and therefore the one place a
    # probe can watch (`Autodev::MrReviewTokenProbe`).
    #
    # `env:`, never `-t`: the binary accepts the flag, but argv is readable via
    # `ps` by every account on the machine for the entire run — up to
    # `mr_review_timeout`, an hour by default. Autodev #10 is the precedent.
    #
    # An empty hash when autodev declares no credential at all. Exporting a blank
    # would be worse than exporting nothing: mr-review's own resolution puts the
    # environment *above* its configuration file, so a blank would override a
    # credential that works.
    def mr_review_env
      token = ::Config.mr_review_token(@config)
      token ? { 'GITLAB_API_TOKEN' => token } : {}
    end

    # Everything a reader needs to act on, in one message (Autodev #49). This
    # used to keep stderr only, and mr-review fails writing nothing there: 15
    # production failures logged 15 empty lines, and three MRs went out
    # unreviewed with the cause discarded right here.
    #
    # Scrubbed because the logger on this path in production is
    # Autodev::JobLogger, which does not scrub (AppLogger does), and mr-review
    # holds the same GitLab PAT autodev does.
    def review_failure_diagnostic(out, err, status)
      streams = { 'stdout' => out.to_s.strip, 'stderr' => err.to_s.strip }
      summary = exit_summary(status)
      return Redactor.scrub("#{summary}, no output on stdout or stderr") if streams.each_value.all?(&:empty?)

      labelled = streams.map { |name, text| "#{name}: #{diagnostic_stream(text)}" }
      Redactor.scrub([summary, *labelled].join("\n"))
    end

    # An empty stream is stated, not left as a dangling colon — that ambiguity is
    # what made the production lines unreadable.
    def diagnostic_stream(text)
      return '(empty)' if text.empty?
      return text if text.length <= DIAGNOSTIC_STREAM_LIMIT

      "#{text[0, DIAGNOSTIC_STREAM_LIMIT]}… (#{text.length - DIAGNOSTIC_STREAM_LIMIT} more characters)"
    end

    # nil when a caller (or a test stub) returns the three-element tuple that
    # predates run_with_timeout handing the status back.
    def exit_summary(status)
      return 'exit status unavailable' if status.nil?
      return "killed by signal #{status.termsig}" if status.signaled?

      "exit #{status.exitstatus}"
    end

    # Per-project override, else the baked default. A review's duration profile is
    # not an implementation call's, which is why this is not dc_timeout.
    def mr_review_timeout
      (@project_config['mr_review_timeout'] || ::Config::MR_REVIEW_TIMEOUT).to_i
    end

    def increment_review_count(issue)
      new_count = (issue.review_count || 0) + 1
      Issue.where(id: issue.id).update(review_count: new_count)
      issue.review_count = new_count
      log "Review count incremented to #{new_count} for issue ##{issue.issue_iid}"
    end

    def command_exists?(cmd)
      _, status = Open3.capture2e('which', cmd)
      status.success?
    end
  end
end
