# frozen_string_literal: true

class IssueProcessor
  # Merge request creation and lookup. Reviews are PipelineMonitor::Reviewer's
  # job — this module used to carry a parallel, never-called copy of that path
  # (removed in Autodev #54).
  module MrManager
    private

    def create_merge_request(work_dir, iid, branch_name, _issue_title)
      existing = find_existing_mr(branch_name)
      return existing if existing

      target = @project_config['target_branch'] || default_branch(work_dir)
      mr_title = run_cmd(['git', 'log', '-1', '--format=%s'], chdir: work_dir)
      mr_body = "#{run_cmd(['git', 'log', '-1', '--format=%B'], chdir: work_dir)}\n\nFixes ##{iid}"

      log "Creating MR: #{mr_title}"
      @client.create_merge_request(@project_path, mr_title,
                                   source_branch: branch_name, target_branch: target, description: mr_body)
    end

    def find_existing_mr(branch_name)
      mrs = @client.merge_requests(@project_path, source_branch: branch_name, state: 'opened')
      return nil unless mrs.any?

      mr = mrs.first
      log "MR already exists: !#{mr.iid}"
      mr
    rescue Gitlab::Error::ResponseError
      nil
    end
  end
end
