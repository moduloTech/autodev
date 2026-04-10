# frozen_string_literal: true

require_relative 'mr_fixer/agent_injector'
require_relative 'mr_fixer/discussion_formatter'
require_relative 'mr_fixer/error_handler'
require_relative 'mr_fixer/fix_cycle'

# Fixes unresolved MR discussions and failed pipeline jobs.
class MrFixer
  include DangerClaudeRunner
  include AgentInjector
  include DiscussionFormatter
  include ErrorHandler
  include FixCycle

  public :apply_label_done, :apply_label_doing

  def initialize(client:, config:, project_config:, logger:, token:)
    init_runner(client: client, config: config, project_config: project_config, logger: logger, token: token)
  end

  def fix(issue)
    log "Checking MR !#{issue.mr_iid} for unresolved discussions (round #{issue.fix_round + 1})..."
    log_activity(issue, :discussions_checking, round: issue.fix_round + 1)
    process_discussions(issue)
  end

  private

  def process_discussions(issue)
    discussions = fetch_unresolved_discussions(issue.mr_iid)
    return transition_no_discussions(issue) if discussions.empty?

    log "Found #{discussions.size} unresolved discussion(s) on MR !#{issue.mr_iid}"
    log_activity(issue, :discussions_found, count: discussions.size)
    execute_fix_cycle(issue, discussions)
  end

  def transition_no_discussions(issue)
    log "No unresolved discussions on MR !#{issue.mr_iid}"
    issue.update(pipeline_retrigger_count: 0)
    issue.discussions_fixed!
    log_activity(issue, :discussions_none)
    log_activity(issue, :pipeline_watch)
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

  def resolve_discussion(mr_iid, discussion_id)
    @client.resolve_merge_request_discussion(@project_path, mr_iid, discussion_id, resolved: true)
    log "Resolved discussion #{discussion_id}"
  rescue Gitlab::Error::ResponseError => e
    log_error "Failed to resolve discussion #{discussion_id}: #{e.message}"
  end
end
