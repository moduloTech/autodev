# frozen_string_literal: true

require_relative 'mr_fixer/agent_injector'
require_relative 'mr_fixer/discussion_formatter'
require_relative 'mr_fixer/error_handler'
require_relative 'mr_fixer/fix_cycle'

# Fixes unresolved MR discussions and failed pipeline jobs.
class MrFixer
  include DangerClaudeRunner
  include MrDiscussions
  include AgentInjector
  include DiscussionFormatter
  include ErrorHandler
  include FixCycle

  public :apply_label_done, :apply_label_doing

  def initialize(client:, config:, project_config:, logger:, token:)
    init_runner(client: client, config: config, project_config: project_config, logger: logger, token: token)
  end

  def fix(issue)
    @dc_issue = issue
    log "Checking MR !#{issue.mr_iid} for unresolved discussions (round #{issue.fix_round + 1})..."
    # Read before the activity note, and before anything else this round does
    # (Autodev #62): an unreadable thread list aborts the round below with the row
    # exactly as the previous cycle left it. `dispatch_discussions` re-enqueues it
    # next cycle, and a note appended per poll would grow for as long as the outage
    # lasts.
    discussions = fetch_unresolved_discussions(issue.mr_iid).map { |d| build_discussion(d) }
    log_activity(issue, :discussions_checking, round: issue.fix_round + 1)
    process_discussions(issue, discussions)
  # The boundary of one fix round. Without it the exception would reach ActiveJob
  # and land the row in Solid Queue's failed executions, which needs a human —
  # for something the next poll cycle retries on its own.
  rescue ApiUnavailableError => e
    log_error "MR !#{issue.mr_iid}: #{e.message} — staying in fixing_discussions for the next cycle"
  end

  private

  def process_discussions(issue, discussions)
    DiscussionSnapshot.capture(context: :pre_mr_fix, client: @client,
                               project_path: @project_path, mr_iid: issue.mr_iid,
                               logger: @logger, issue: issue)
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

  # The fetch itself and `resolved?` live in `MrDiscussions` since Autodev #62 —
  # this class held a second, byte-for-byte copy of both, and only the other one
  # was on the delivery path. What is genuinely MrFixer's is the shape: a title and
  # the notes, to build a prompt from.
  def build_discussion(discussion)
    first_note = discussion.notes.first
    { id: discussion.id, title: first_note.body.to_s[0, 80], notes: discussion.notes }
  end

  # A write, not a read: failing to mark a thread resolved leaves it unresolved,
  # which the next round re-reads. No verdict is inferred from the failure, so it
  # does not go through `GitlabHelpers.answer`.
  def resolve_discussion(mr_iid, discussion_id)
    @client.resolve_merge_request_discussion(@project_path, mr_iid, discussion_id, resolved: true)
    log "Resolved discussion #{discussion_id}"
  rescue Gitlab::Error::ResponseError => e
    log_error "Failed to resolve discussion #{discussion_id}: #{e.message}"
  end
end
