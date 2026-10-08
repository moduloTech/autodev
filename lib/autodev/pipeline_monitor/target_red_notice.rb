# frozen_string_literal: true

class PipelineMonitor
  # What autodev says about a job already red on the target branch (Autodev
  # #130): the activity line, the merge request comment, and the give-up when the
  # target never recovers. `PreexistingFailures` decides; this announces.
  module TargetRedNotice
    # The activity line rewritten in place on every poll of a hold, so the note
    # does not grow (Autodev #53's concern).
    PREEXISTING_PATTERN = /— :construction: (Deja en echec sur|Already failing on)/

    private

    # The activity line on every poll that sets a job aside (rewritten in place),
    # and one comment on the merge request per (pipeline, job set).
    def note_preexisting(issue, pipeline, verdict)
      vars = preexisting_vars(verdict)
      log_activity(issue, :pipeline_preexisting, replace_pattern: PREEXISTING_PATTERN, **vars)
      key = "#{pipeline_id(pipeline)}:#{verdict.jobs.sort.join(',')}"
      return if issue.preexisting_noted_key == key

      issue.update(preexisting_noted_key: key) if post_preexisting_note(issue, vars)
    end

    # An announcement: a failure is logged and not recorded, so the next poll
    # posts it.
    def post_preexisting_note(issue, vars)
      body = Locales.t(:pipeline_preexisting_mr_note, locale: (issue.locale || 'fr').to_sym, tag: autodev_tag, **vars)
      @client.create_merge_request_note(@project_path, issue.mr_iid, body)
      true
    rescue ::Gitlab::Error::ResponseError, ::SystemCallError, ::Timeout::Error, ::SocketError,
           ::OpenSSL::SSL::SSLError, ::EOFError => e
      log_error "Failed to comment on MR !#{issue.mr_iid} about pre-existing jobs: #{e.class}: #{e.message}"
      false
    end

    def preexisting_vars(verdict)
      { jobs: verdict.jobs.join(', '), target_branch: verdict.target_branch,
        target_pipeline: pipeline_id(verdict.pipeline),
        target_url: GitlabHelpers.field(verdict.pipeline, :web_url).to_s }
    end

    # The age bound reached on a poll that held: the truth is that the target is
    # still red, not that the watch "never reached a verdict" — which is what
    # `pipeline_watch_expired` says, and what would be false here.
    def give_up_on_red_target(issue, days)
      verdict = @target_red_hold
      log "Issue ##{issue.issue_iid}: #{verdict.target_branch} still red after #{days} days → done"
      abandon_issue(issue, :target_pipeline_red, detail: verdict.jobs.join(', '), days: days,
                                                 **preexisting_vars(verdict))
    end
  end
end
