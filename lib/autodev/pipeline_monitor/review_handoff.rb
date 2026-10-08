# frozen_string_literal: true

require_relative 'review_handoff_vocabulary'
require_relative 'review_handoff_scripts'
require_relative 'review_handoff_draw'
require_relative 'review_handoff_writes'

class PipelineMonitor
  # A delivered merge request reaches its reviewer (Autodev #90).
  #
  # Autodev delivers by posing `label_done` on the *ticket*; a human merge
  # request on the same project also arrives with `MR::` labels, a reviewer and
  # an assignee on the *merge request*, written by the author-side skill's
  # materialization. Autodev's never did — 38 of the last 50 on powerpanne/core
  # were labelled by hand afterwards.
  #
  # For a project that declares `review_size_command` (and optionally
  # `review_coverage_command`, `reviewer_draw_command`), the project's scripts
  # compute and autodev writes, with its own token — the Autodev #74 invariant
  # one step further. It never runs the project's materializer, never rewrites
  # the title or description, and posts no review summary.
  #
  # Called as the last statement of `finalize_green_done` and never raises: it
  # runs after a terminal transition, and nothing it does may skip the
  # handback, the stamp or the comment before it (Autodev #126). Every outcome
  # is one activity entry; none changes the row, its flag or the ticket.
  module ReviewHandoff
    include ReviewHandoffVocabulary
    include ReviewHandoffScripts
    include ReviewHandoffDraw
    include ReviewHandoffWrites

    private

    def hand_off_for_review(issue)
      commands = handoff_commands
      return unless commands

      @handoff_read_back = nil
      run_handoff(issue, commands)
    rescue Stop => e
      log_activity(issue, e.key, **e.vars)
    rescue StandardError => e
      log_error "Issue ##{issue.issue_iid}: review handoff failed: #{e.class}: #{e.message}"
      key, vars = failure_entry(e)
      log_activity(issue, key, **vars, reason: Redactor.scrub("#{e.class}: #{e.message}")[0, 300])
    end

    # GitLab not answering the read-back of a write it was sent is "not
    # confirmed" (`ReviewHandoffWrites#read_back`); anything else interrupted
    # the handoff.
    def failure_entry(error)
      return @handoff_read_back if @handoff_read_back && error.is_a?(ApiUnavailableError)

      [:review_handoff_failed, {}]
    end

    def handoff_commands
      size = @project_config['review_size_command']
      return unless size.is_a?(Array) && size.any?

      { size: size, coverage: @project_config['review_coverage_command'],
        draw: @project_config['reviewer_draw_command'] }
    end

    def run_handoff(issue, commands)
      mr = read_handoff_mr(issue)
      refs = diff_ends(mr)
      work_dir = "/tmp/autodev_review_handoff_#{@project_path.tr('/', '_')}_#{issue.issue_iid}"
      clone_for_handoff(work_dir, issue, refs)
      measurement = measure(work_dir, commands, placeholder_vars(issue, mr, refs), mr)
      write_handoff(issue, mr, measurement)
    ensure
      FileUtils.rm_rf(work_dir) if work_dir
    end

    def read_handoff_mr(issue)
      GitlabHelpers.answer(:merge_request) { @client.merge_request(@project_path, issue.mr_iid) }
    end

    def diff_ends(merge_request)
      refs = GitlabHelpers.field(merge_request, :diff_refs)
      base = refs && GitlabHelpers.field(refs, :base_sha)
      head = refs && GitlabHelpers.field(refs, :head_sha)
      raise Stop.new(:review_handoff_not_measured, reason: 'diff_refs') if base.to_s.empty? || head.to_s.empty?

      { base: base, head: head }
    end

    def placeholder_vars(issue, merge_request, refs)
      author = GitlabHelpers.field(merge_request, :author)
      { mr_iid: issue.mr_iid, base_sha: refs[:base], head_sha: refs[:head],
        source_branch: GitlabHelpers.field(merge_request, :source_branch),
        target_branch: GitlabHelpers.field(merge_request, :target_branch),
        mr_author: author && GitlabHelpers.field(author, :username) }
    end

    def measure(work_dir, commands, vars, merge_request)
      size = measure_size(work_dir, commands[:size], vars)
      zone = measure_zone(work_dir, commands[:coverage], vars)
      draw = draw_reviewers(work_dir, commands[:draw], vars.merge(size: size), zone == 'red', merge_request)
      Measurement.new(size, zone, draw)
    end

    def measure_size(work_dir, command, vars)
      result = run_handoff_script(work_dir, handoff_argv(command, vars))
      size = result.success? ? result.json['class'] : nil
      return size if SIZE_CLASSES.include?(size)

      raise Stop.new(:review_handoff_not_measured,
                     reason: result.success? ? "class #{size.inspect}" : script_reason(result))
    end

    # Optional, and a failure omits the label rather than stopping: the skill's
    # rule for an unmeasured zone, applied to an unmeasurable one.
    def measure_zone(work_dir, command, vars)
      return if command.blank?

      result = run_handoff_script(work_dir, handoff_argv(command, vars))
      zone = result.success? ? result.json['zone'] : nil
      COVERAGE_ZONE_LABELS.key?(zone) ? zone : nil
    end

    def current_labels(merge_request)
      Array(GitlabHelpers.field(merge_request, :labels)).map(&:to_s)
    end
  end
end
