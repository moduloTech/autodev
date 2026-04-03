# frozen_string_literal: true

class IssueProcessor
  # Merge request creation, label management, and review execution.
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

    def update_labels(iid)
      labels_to_remove = @project_config['labels_to_remove'] || []
      label_to_add     = @project_config['label_to_add']

      gi = @client.issue(@project_path, iid)
      current_labels = gi.labels || []
      new_labels = current_labels - labels_to_remove
      new_labels << label_to_add if label_to_add && !new_labels.include?(label_to_add)
      @client.edit_issue(@project_path, iid, labels: new_labels.join(','))
      log "Labels updated: removed #{labels_to_remove & current_labels}, added #{label_to_add}"
    rescue Gitlab::Error::ResponseError => e
      log_error "Failed to update labels for ##{iid}: #{e.message}"
    end

    def run_review(mr_url)
      unless command_exists?('mr-review')
        log 'mr-review not installed, skipping review'
        return
      end

      log 'Waiting 15s for GitLab to compute diff_refs...'
      sleep 15
      execute_review(mr_url)
    rescue StandardError => e
      log_error "mr-review error (non-fatal): #{e.message}"
    end

    def execute_review(mr_url)
      log "Running mr-review on #{mr_url}..."
      _, err, status = Open3.capture3(CLEAN_ENV, 'mr-review', '-H', mr_url)
      status.success? ? log('Review completed successfully') : log_error("mr-review failed (non-fatal): #{err[0, 300]}")
    end

    def command_exists?(cmd)
      _, status = Open3.capture2e('which', cmd)
      status.success?
    end
  end
end
