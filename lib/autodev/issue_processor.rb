# frozen_string_literal: true

require_relative 'issue_processor/git_operations'
require_relative 'issue_processor/spec_checker'
require_relative 'issue_processor/implementer'
require_relative 'issue_processor/parallel_runner'
require_relative 'issue_processor/mr_manager'
require_relative 'issue_processor/error_handler'

# Processes a single GitLab issue through the full implementation lifecycle.
class IssueProcessor
  include DangerClaudeRunner
  include GitOperations
  include SpecChecker
  include Implementer
  include ParallelRunner
  include MrManager
  include ErrorHandler

  def initialize(client:, config:, project_config:, logger:, token:)
    init_runner(client: client, config: config, project_config: project_config, logger: logger, token: token)
  end

  def process(issue)
    start_processing(issue)
    return if issue_closed?(issue)

    @work_dir = work_dir_for(issue)
    execute_pipeline(issue, @work_dir)
  rescue RateLimitError => e
    handle_rate_limit(issue, e)
  rescue StandardError => e
    handle_process_error(issue, e)
  ensure
    FileUtils.rm_rf(@work_dir) if @work_dir && Dir.exist?(@work_dir)
  end

  private

  def work_dir_for(issue)
    "/tmp/autodev_#{@project_path.gsub('/', '_')}_#{issue.issue_iid}"
  end

  def start_processing(issue)
    log "Processing issue ##{issue.issue_iid}: #{issue.issue_title}"
    issue.start_processing!
    Issue.where(id: issue.id).update(started_at: Sequel.lit("datetime('now')"))
    apply_label_doing(issue.issue_iid)
    log_activity(issue, :started)
  end

  def issue_closed?(issue)
    current = @client.issue(@project_path, issue.issue_iid)
    return false if current.state == 'opened'

    log "Issue ##{issue.issue_iid} is no longer open (#{current.state}), skipping"
    issue._issue_closed = true
    issue.clone_complete!
    Issue.where(id: issue.id).update(finished_at: Sequel.lit("datetime('now')"))
    true
  end

  def execute_pipeline(issue, work_dir)
    iid = issue.issue_iid
    assign_to_self(iid)
    notify_localized(iid, :processing_started)
    branch = clone_and_prepare(issue, iid, work_dir)
    finalize(issue, iid, branch, work_dir) unless issue.done? || issue.needs_clarification? || issue.answering_question?
  end

  def run_implementation(issue, work_dir, iid, _branch)
    context = GitlabHelpers.fetch_full_context(
      @client, @project_path, iid,
      mr_iid: issue.mr_iid, gitlab_url: @gitlab_url, token: @token, work_dir: work_dir
    )
    return if check_specification(work_dir, context, iid, issue)

    prepare_and_implement(issue, work_dir, context, iid)
  end

  def prepare_and_implement(issue, work_dir, context, iid)
    ensure_claude_md(work_dir)
    @all_skills = SkillsInjector.inject(work_dir, logger: @logger, project_path: @project_path)[:all_skills]
    log_activity(issue, :implementing)
    run_and_push(issue, work_dir, context, iid)
  end

  def run_and_push(issue, work_dir, context, iid)
    implement(work_dir, context, iid)
    upload_screenshots(iid)
    issue.impl_complete!
    danger_claude_commit(work_dir)
    issue.commit_complete!
    verify_changes(work_dir, @current_branch_name)
    push(work_dir, @current_branch_name)
    issue.push_complete!
    log_activity(issue, :changes_pushed, branch: @current_branch_name)
  end

  def upload_screenshots(iid)
    ScreenshotUploader.process(client: @client, project_path: @project_path, iid: iid, logger: @logger)
  end

  def finalize(issue, iid, branch_name, work_dir)
    merge_request = create_merge_request(work_dir, iid, branch_name, issue.issue_title)
    issue.update(mr_iid: merge_request.iid, mr_url: merge_request.web_url)
    issue.mr_created!
    persist_finalize(issue)
    log_activity(issue, :mr_created, mr_url: merge_request.web_url)
    notify_localized(iid, :mr_created, mr_url: merge_request.web_url)
    log_activity(issue, :pipeline_watch)
    log "Issue ##{iid} completed: #{merge_request.web_url}"
  end

  def persist_finalize(issue)
    Issue.where(id: issue.id).update(
      finished_at: Sequel.lit("datetime('now')"), pipeline_retrigger_count: 0,
      dc_stdout: @dc_stdout, dc_stderr: @dc_stderr
    )
  end
end
