# frozen_string_literal: true

class PipelineMonitor
  # The writing half of `ReviewHandoff` (Autodev #90): what autodev writes on
  # the merge request with its own token, and the read-back that decides
  # whether it landed.
  module ReviewHandoffWrites
    include ReviewHandoffVocabulary

    private

    # Three writes, each read back before the next: the measured labels with
    # the reviewer and the assignee, then the reviewer labels, then Ready.
    #
    # The reviewer labels come only once the designation has landed
    # (adversarial review). Written together, a reviewer GitLab dropped left
    # `MR::Reviewer::*` labels behind, and the next delivery read them as "a
    # reviewer is already designated", kept them and posted Ready on a merge
    # request nobody had been asked to review.
    def write_handoff(issue, merge_request, measurement)
      current = current_labels(merge_request)
      designated = measurement.draw.is_a?(Array) ? measurement.draw : nil
      write_and_verify(issue, label_plan(current, measured_targets(measurement)), designated)
      refuse_without_reviewer(measurement) if measurement.draw.is_a?(Stop)
      write_reviewer_labels(issue, current, designated) if designated
      post_ready(issue, current)
      key, vars = ready_entry(measurement, designated)
      log_activity(issue, key, **vars)
    end

    def write_reviewer_labels(issue, current, designated)
      write_and_verify(issue, label_plan(current, REVIEWER_PREFIX => designated.map(&:label).uniq), nil)
    end

    # The draw's own outcome, plus what was written all the same, so the entry
    # never claims a coverage label that was not posted.
    def refuse_without_reviewer(measurement)
      stop = measurement.draw
      raise Stop.new(stop.key, **stop.vars, labels: written_labels(measurement).join(', '))
    end

    # Remove-then-add per managed prefix, `MrMaterialize::LabelPlan`'s shape:
    # GitLab CE has no scoped-label exclusivity. A dimension not measured is
    # left alone.
    def label_plan(current, targets)
      targets.each_with_object({ add: [], remove: [] }) do |(prefix, wanted), plan|
        plan[:remove].concat(current.select { |label| label.start_with?(prefix) } - wanted)
        plan[:add].concat(wanted - current)
      end
    end

    def measured_targets(measurement)
      targets = { SIZE_PREFIX => [size_label(measurement)] }
      targets[COVERAGE_PREFIX] = [coverage_label(measurement)] if measurement.zone
      targets
    end

    def written_labels(measurement)
      measured_targets(measurement).values.flatten
    end

    # One reviewer and one assignee — GitLab CE holds one of each and drops a
    # second reviewer silently. One drawn developer is both; two: the first
    # reviews, the second is assigned.
    def write_and_verify(issue, plan, designated)
      attrs = label_attrs(plan)
      attrs.merge!(reviewer_ids: [designated.first.id], assignee_id: designated.last.id) if designated
      return if attrs.empty?

      edit_handoff_mr(issue, attrs)
      verify_landed(issue, plan, designated)
    end

    def label_attrs(plan)
      { add_labels: plan[:add], remove_labels: plan[:remove] }
        .reject { |_, labels| labels.empty? }.transform_values { |labels| labels.join(',') }
    end

    def edit_handoff_mr(issue, attrs)
      GitlabHelpers.answer(:edit_merge_request) { @client.edit_merge_request(@project_path, issue.mr_iid, attrs) }
    end

    # A write that did not raise is not a write that landed (GitLab CE accepts
    # and ignores a second reviewer, Autodev #126 measured the same of an
    # assignee): one read, every claim checked.
    def verify_landed(issue, plan, designated)
      back = read_handoff_mr(issue)
      labels = current_labels(back)
      missing = (plan[:add] - labels) + (plan[:remove] & labels).map { |label| "-#{label}" }
      missing.concat(designation_mismatches(back, designated)) if designated
      raise Stop.new(:review_handoff_not_landed, what: missing.join(', ')) if missing.any?
    end

    def designation_mismatches(merge_request, designated)
      reviewer, assignee = designated.first, designated.last # rubocop:disable Style/ParallelAssignment
      mismatches = []
      mismatches << "reviewer #{reviewer.username}" unless user_ids(merge_request, :reviewers) == [reviewer.id]
      mismatches << "assignee #{assignee.username}" unless user_ids(merge_request, :assignees) == [assignee.id]
      mismatches
    end

    def user_ids(merge_request, role)
      Array(GitlabHelpers.field(merge_request, role)).map { |user| GitlabHelpers.field(user, :id) }
    end

    # Last, and only once everything declared produced its result and read
    # back — the skill's own rule.
    def post_ready(issue, labels_before)
      return if labels_before.include?(READY_LABEL)

      edit_handoff_mr(issue, add_labels: READY_LABEL)
      verify_landed(issue, { add: [READY_LABEL], remove: [] }, nil)
    end

    def ready_entry(measurement, designated)
      vars = { size: size_label(measurement), coverage: measurement.zone ? coverage_label(measurement) : '—' }
      return [:review_handoff_ready_reviewer_kept, vars] if measurement.draw == :kept
      return [:review_handoff_ready_no_draw, vars] if measurement.draw == :not_declared

      [:review_handoff_ready, vars.merge(reviewer: designated.first.username, assignee: designated.last.username)]
    end

    def size_label(measurement) = "#{SIZE_PREFIX}#{measurement.size_class}"
    def coverage_label(measurement) = "#{COVERAGE_PREFIX}#{COVERAGE_ZONE_LABELS.fetch(measurement.zone)}"
  end
end
