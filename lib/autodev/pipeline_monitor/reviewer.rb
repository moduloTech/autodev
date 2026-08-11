# frozen_string_literal: true

class PipelineMonitor
  # Runs mr-review on the MR after a green pipeline.
  # Manages review_count and transitions via review_done!.
  module Reviewer
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

    def launch_review(issue)
      log "Launching mr-review for MR !#{issue.mr_iid} (review_count: #{issue.review_count})"
      log_activity(issue, :reviewing)
      if execute_mr_review(issue)
        finalize_review_success(issue)
      else
        finalize_review_failure(issue)
      end
    end

    def finalize_review_success(issue)
      increment_review_count(issue)
      reset_review_failure_count(issue)
      DiscussionSnapshot.capture(context: :post_mr_review, client: @client,
                                 project_path: @project_path, mr_iid: issue.mr_iid,
                                 logger: @logger, issue: issue)
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

    def give_up_reviewing(issue)
      issue.review_giveup!
      apply_label_done(issue.issue_iid)
      reassign_to_author(issue)
      Issue.where(id: issue.id).update_all(finished_at: Time.current, needs_attention: true,
                                           attention_reason: 'review_failures_exhausted')
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
      unless command_exists?('mr-review')
        log 'mr-review not installed, skipping review'
        return false
      end

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
      out, err, ok, status = run_with_timeout('mr-review', ['-H', mr_url], chdir: Dir.pwd,
                                                                           timeout: mr_review_timeout)
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
