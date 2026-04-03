# frozen_string_literal: true

require_relative 'mr_fixer/discussion_formatter'
require_relative 'mr_fixer/error_handler'
require_relative 'mr_fixer/fix_cycle'

# Fixes unresolved MR discussions and failed pipeline jobs.
class MrFixer
  include DangerClaudeRunner
  include DiscussionFormatter
  include ErrorHandler
  include FixCycle

  public :cleanup_labels, :apply_label_todo, :apply_label_mr

  def initialize(client:, config:, project_config:, logger:, token:)
    init_runner(client: client, config: config, project_config: project_config, logger: logger, token: token)
  end

  def fix(issue)
    log "Checking MR !#{issue.mr_iid} for unresolved discussions (round #{issue.fix_round + 1})..."
    return unless verify_trigger_label(issue.issue_iid)

    discussions = fetch_unresolved_discussions(issue.mr_iid)
    return transition_no_discussions(issue) if discussions.empty?

    log "Found #{discussions.size} unresolved discussion(s) on MR !#{issue.mr_iid}"
    execute_fix_cycle(issue, discussions)
  end

  DEFAULT_MR_FIXER_AGENT = <<~AGENT
    ---
    name: mr-fixer
    description: Fix MR review comments. Use proactively when fixing code review discussions.
    memory: project
    model: sonnet
    ---

    You are a senior developer fixing code review comments on a Merge Request.

    ## Behavior

    Before starting, check your agent memory for patterns you have seen before on this project.

    When fixing a review comment:
    1. Read the diff hunk and the reviewer's comment carefully.
    2. Understand the intent of the original code (see the issue context).
    3. Make the minimal change that addresses the comment.
    4. Do not refactor surrounding code unless the comment explicitly asks for it.
    5. Do not change tests unless the comment is about tests.

    ## Memory

    After fixing all comments, update your agent memory with:
    - Recurring reviewer patterns (e.g., "reviewer X always requests guard clauses")
    - Common mistakes you fixed (e.g., "missing null check on association")
    - Project conventions you discovered that are not in CLAUDE.md
    - Patterns that led to incorrect fixes so you can avoid them next time

    Write concise notes. Focus on what will help you fix faster next time.
  AGENT

  private

  def verify_trigger_label(iid)
    trigger_label = @config['trigger_label']
    gi = @client.issue(@project_path, iid)
    return true if gi.labels&.include?(trigger_label)

    log "Issue ##{iid} no longer has '#{trigger_label}' label, skipping"
    false
  rescue Gitlab::Error::ResponseError => e
    log_error "Cannot fetch issue ##{iid}: #{e.message}"
    false
  end

  def transition_no_discussions(issue)
    log "No unresolved discussions on MR !#{issue.mr_iid}"
    issue.update(pipeline_retrigger_count: 0)
    issue.discussions_fixed!
    log "Issue ##{issue.issue_iid}: no discussions to fix → checking_pipeline"
  end

  def fetch_unresolved_discussions(mr_iid)
    raw = @client.merge_request_discussions(@project_path, mr_iid)
    raw.select { |d| d.notes&.any? && !resolved?(d) }.map { |d| build_discussion(d) }
  rescue Gitlab::Error::ResponseError => e
    log_error "Failed to fetch MR discussions: #{e.message}"
    []
  end

  def build_discussion(discussion)
    first_note = discussion.notes.first
    { id: discussion.id, title: first_note.body.to_s[0, 80], notes: discussion.notes }
  end

  def resolved?(discussion)
    resolvable_notes = discussion.notes.select { |n| n.respond_to?(:resolvable) && n.resolvable }
    return true if resolvable_notes.empty?

    resolvable_notes.all? { |n| n.respond_to?(:resolved) && n.resolved }
  end

  # Returns the agent name, injecting a default if needed.
  # Priority: config override > project agent > injected default.
  def detect_agent(work_dir, default_name)
    config_agent = @project_config['mr_fixer_agent']
    return config_agent if config_agent

    agent_path = File.join(work_dir, '.claude', 'agents', "#{default_name}.md")
    if File.exist?(agent_path)
      log "Found agent '#{default_name}' in project"
      return default_name
    end

    inject_default_mr_fixer_agent(work_dir, agent_path)
    default_name
  end

  def inject_default_mr_fixer_agent(_work_dir, agent_path)
    log 'Injecting default mr-fixer agent'
    FileUtils.mkdir_p(File.dirname(agent_path))
    File.write(agent_path, DEFAULT_MR_FIXER_AGENT)
  end

  def default_branch(work_dir)
    out, _err, ok = run_cmd_status(%w[git symbolic-ref refs/remotes/origin/HEAD --short], chdir: work_dir)
    ok && !out.strip.empty? ? out.strip.sub('origin/', '') : 'main'
  end

  def resolve_discussion(mr_iid, discussion_id)
    @client.resolve_merge_request_discussion(@project_path, mr_iid, discussion_id, resolved: true)
    log "Resolved discussion #{discussion_id}"
  rescue Gitlab::Error::ResponseError => e
    log_error "Failed to resolve discussion #{discussion_id}: #{e.message}"
  end
end
