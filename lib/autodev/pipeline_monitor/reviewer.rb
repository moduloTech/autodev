# frozen_string_literal: true

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
    # `ConfigError` (a declared skill missing from the clone) is deliberately not
    # among them and keeps escaping: see the error catalogue in CLAUDE.md. Rescuing
    # it would write an activity row every poll, which keeps the row out of
    # `DormantAudit`'s active arm forever *and* restarts the age clock — an
    # unbounded, unsignalled loop, strictly worse than parking.
    def launch_review(issue)
      skill = @project_config['review_skill'].presence
      log "Launching review for MR !#{issue.mr_iid} " \
          "(#{skill ? "skill '#{skill}'" : 'mr-review binary'}, review_count: #{issue.review_count})"
      log_activity(issue, :reviewing)
      dispatch_review_outcome(issue, skill ? review_with_skill(issue) : execute_mr_review(issue))
    # A GitLab outage while *we* publish is not a review failure and must not spend
    # the budget (Autodev #62, #71) — so neither counter is touched — but the row
    # still has to come back to `checking_pipeline` before the poll aborts at
    # `PipelineMonitor#check`'s boundary, or nothing re-enqueues it. Re-raised so
    # the abort still happens and `abandon_expired_watch` stays unreached.
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
      log "mr-review failed (consecutive failures: #{new_failures}/#{REVIEW_FAILURE_THRESHOLD})"
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
      log "Issue ##{issue.issue_iid}: #{REVIEW_FAILURE_THRESHOLD} consecutive mr-review failures → done"
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
    # chdir: Dir.pwd keeps the previous behaviour. Open3.capture3 inherited the
    # process's cwd, and mr-review works through the GitLab API rather than in a
    # local clone, so it has no repo to sit in.
    #
    # Both streams and the exit status are reported on failure (Autodev #49).
    # Keeping stderr alone made every production failure log the same empty line,
    # because mr-review writes nothing there.
    def run_mr_review_command(mr_url)
      log "Running mr-review on #{mr_url}..."
      dc_heartbeat!('mr-review')
      out, err, ok, status = run_with_timeout('mr-review', ['-H', mr_url], chdir: Dir.pwd, timeout: mr_review_timeout)
      return log('Review completed successfully') || true if ok

      log_error "mr-review failed (non-fatal): #{review_failure_diagnostic(out, err, status)}"
      false
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
