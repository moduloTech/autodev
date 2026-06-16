# frozen_string_literal: true

# HTTP surface for AutospecDraft — listing + creation + show page +
# chat/apply_suggestion actions on a draft (phase D step 9c-10a).
# See autodev/docs/autospec.md §A, §E, §G for the underlying design,
# and `docs/design/spec_update/README.md` for the eventual visual target
# (which lands in step 10b/10c — 10a is the functional MVP).
#
# Author-only at the MVP — owners can vote on submitted drafts in
# step 11 but cannot chat on or apply suggestions to someone else's
# drafting work. The wider owner/contributor matrix (§J) is wired
# along with the approval orchestration.
#
# `chat` and `apply_suggestion` respond to both HTML (redirect back to
# the show page — used by the 10a plain-form composer + apply buttons)
# and JSON (returned for tests + any future async client). Token-level
# SSE streaming is intentionally deferred — see autospec.md §L's "à
# acter au moment où le streaming AutoSpec passe en intégration":
# without a frontend to measure UX against, streaming would ship code
# with no test customer. Step 10b/10c can rebind `chat` to
# ActionController::Live + the SDK's `messages.stream(…)` once the
# typing-effect UX is validated.
class AutospecDraftsController < ApplicationController # rubocop:disable Metrics/ClassLength
  include ::Web::Helpers

  before_action :load_draft, except: %i[index new create import create_from_import]
  before_action :authorize_view!, only: :show
  before_action :authorize_voter!, only: %i[approve reject]
  before_action :authorize_author!,
                except: %i[index new create show approve reject import create_from_import]

  rescue_from Autospec::SuggestionApplier::AlreadyApplied,
              with: -> { render_apply_error('already_applied', :conflict) }
  rescue_from Autospec::SuggestionApplier::ToolUseNotFound,
              with: -> { render_apply_error('tool_use_not_found', :not_found) }
  rescue_from Autospec::SuggestionApplier::UnsupportedTool,
              with: -> { render_apply_error('unsupported_tool', :unprocessable_entity) }
  rescue_from Autospec::ApprovalRecorder::AlreadyVoted,
              with: -> { render_apply_error('already_voted', :conflict) }
  rescue_from Autospec::ApprovalRecorder::DraftNotPending,
              with: -> { render_apply_error('draft_not_pending_approval', :conflict) }
  rescue_from Autospec::ApprovalRecorder::NotAnOwner,
              with: -> { render_apply_error('not_an_owner', :forbidden) }

  # GET /autospec_drafts
  def index
    drafts = current_user.autospec_drafts.includes(:project).order(updated_at: :desc)
    render html: Web::Views::AutospecDrafts::Index.new(drafts: drafts, **view_kwargs).call.html_safe,
           layout: false
  end

  # GET /autospec_drafts/new
  def new
    render html: Web::Views::AutospecDrafts::New.new(
      projects: current_user.visible_projects.order(:slug), **view_kwargs
    ).call.html_safe, layout: false
  end

  # POST /autospec_drafts
  def create
    project = current_user.visible_projects.find_by(id: params[:project_id])
    return redirect_to('/autospec_drafts/new', alert: 'project_unavailable') unless project

    draft = AutospecDraft.create!(user: current_user, project: project,
                                  title: params[:title].presence,
                                  markdown: params[:markdown].presence)
    redirect_to "/autospec_drafts/#{draft.id}"
  end

  # GET /autospec_drafts/import — paste a GitLab issue URL to backfill
  # an AutoSpec draft pre-populated with the issue's title + body.
  # Lowest-priority §A path: useful during the pilot to migrate
  # already-filed tickets into the workflow without retyping.
  def import
    render html: Web::Views::AutospecDrafts::Import.new(**view_kwargs).call.html_safe,
           layout: false
  end

  # POST /autospec_drafts/import
  def create_from_import
    draft = Autospec::GitlabImporter.new(params[:url].to_s, current_user).call
    redirect_to "/autospec_drafts/#{draft.id}"
  rescue Autospec::GitlabImporter::InvalidUrl
    redirect_to('/autospec_drafts/import', alert: 'import_invalid_url')
  rescue Autospec::GitlabImporter::ProjectNotFound
    redirect_to('/autospec_drafts/import', alert: 'import_project_not_found')
  rescue Autospec::GitlabImporter::ProjectNotVisible
    redirect_to('/autospec_drafts/import', alert: 'import_project_not_visible')
  rescue Autospec::GitlabImporter::IssueNotFound
    redirect_to('/autospec_drafts/import', alert: 'import_issue_not_found')
  end

  # GET /autospec_drafts/:id
  def show
    render html: Web::Views::AutospecDrafts::Show.new(
      draft: @draft, messages: @draft.autospec_messages.order(:id),
      attachments: @draft.autospec_attachments.with_attached_file.order(:created_at),
      chat_enabled: Autospec::Chat.api_key_configured?,
      capabilities: draft_capabilities,
      current_iteration_votes: current_iteration_votes,
      already_voted: already_voted?, **view_kwargs
    ).call.html_safe, layout: false
  end

  # PATCH /autospec_drafts/:id — inline + autosave updates from the
  # editor (title, markdown, meta_chips). Edits are only legal while the
  # draft is in `drafting`; once it moves to `pending_approval` the
  # author must `retract!` first (step 11). 409 + a stable error key let
  # the autosave loop surface "this draft is locked" without scraping HTML.
  #
  # `meta_chips` is sliced to the keys SuggestionApplier knows about
  # (cf. META_KEYS) — anything else would silently expand the JSON
  # column and confuse the model on the next chat turn.
  def update
    return render_apply_error('draft_locked', :conflict) unless @draft.drafting?

    attrs = update_attrs
    attrs[:meta_chips] = attrs[:meta_chips].slice(*Autospec::SuggestionApplier::META_KEYS) if attrs[:meta_chips]
    @draft.update!(attrs)
    respond_to do |format|
      format.html { redirect_to "/autospec_drafts/#{@draft.id}" }
      format.json { render json: { draft: serialise_draft(@draft) } }
    end
  end

  # POST /autospec_drafts/:id/chat — short-circuits to 503 instead of
  # 500'ing inside the service when the Anthropic key isn't set. The
  # autosave loop / chat composer disabled state already cover the
  # client-side; this is the server-side guard.
  def chat
    return render_apply_error('chat_unavailable', :service_unavailable) unless Autospec::Chat.api_key_configured?

    message = Autospec::Chat.new(@draft).reply(user_content: params.require(:message).to_s)
    respond_to do |format|
      format.html { redirect_to "/autospec_drafts/#{@draft.id}" }
      format.json { render json: { message: serialise_message(message) } }
    end
  end

  # POST /autospec_drafts/:id/apply_suggestion
  def apply_suggestion
    message = @draft.autospec_messages.find(params.require(:message_id))
    result = Autospec::SuggestionApplier.new(message, params.require(:tool_use_id).to_s).call
    render_apply_result(result)
  end

  # POST /autospec_drafts/:id/submit_for_approval — author clicks
  # "Créer le ticket". Destination ('human' or 'autodev') is set on the
  # draft transactionally before the AASM transition so the post-finalize
  # GitlabSubmitter (step 11d) can read it from the row. The 'autodev'
  # choice is owner-only (autospec.md §J — the "send to AutoDev" gate
  # is a deliberate product lock).
  def submit_for_approval # rubocop:disable Metrics/MethodLength
    return render_apply_error('draft_not_drafting', :conflict) unless @draft.drafting?

    destination = params[:destination].to_s
    unless AutospecDraft::DESTINATIONS.include?(destination)
      return render_apply_error('destination_invalid', :unprocessable_entity)
    end
    unless @draft.destination_choosable_by?(current_user, destination)
      return render_apply_error('destination_forbidden', :forbidden)
    end

    @draft.transaction do
      @draft.update!(destination: destination)
      @draft.submit_for_approval!
    end
    render_draft_response
  end

  # POST /autospec_drafts/:id/retract — author pulls a pending_approval
  # draft back to drafting. The iteration is intentionally NOT decremented
  # (cf. AutospecDraft#retract — old approvals stay tagged with the older
  # iteration so the audit trail is intact; the next submit bumps the
  # iteration further and stale rows are ignored).
  def retract
    return render_apply_error('draft_not_pending_approval', :conflict) unless @draft.pending_approval?

    @draft.retract!
    render_draft_response
  end

  # POST /autospec_drafts/:id/approve — owner records an approval vote.
  # Quorum (all owners approved at current_iteration) triggers
  # `finalize!` on the draft through the ApprovalRecorder service.
  def approve
    Autospec::ApprovalRecorder.new(@draft, current_user).record_approval!
    render_draft_response
  end

  # POST /autospec_drafts/:id/reject — owner records a rejection vote
  # with a mandatory reason. First rejection at the current iteration
  # immediately flips the draft to `rejected`.
  def reject
    reason = params[:reason].to_s.strip
    return render_apply_error('reason_required', :unprocessable_entity) if reason.empty?

    Autospec::ApprovalRecorder.new(@draft, current_user).record_rejection!(reason)
    render_draft_response
  end

  private

  def load_draft
    @draft = AutospecDraft.find(params[:id])
  end

  def authorize_author!
    return if @draft.user_id == current_user.id

    respond_to do |format|
      format.html { head :forbidden }
      format.json { render json: { error: 'forbidden' }, status: :forbidden }
    end
  end

  # Approve / reject endpoints are owner-only — author may or may not
  # be an owner (an owner-author validates their own draft per §A).
  # `votable_by?` encodes both the role AND the `pending_approval`
  # state requirement. We surface both as 403 from the gate; the
  # already-voted (409) check is enforced inside ApprovalRecorder.
  def authorize_voter!
    return if @draft.votable_by?(current_user)

    respond_to do |format|
      format.html { head :forbidden }
      format.json { render json: { error: 'not_an_owner' }, status: :forbidden }
    end
  end

  # Looser than `authorize_author!` — owners of the project can also
  # see the draft once it reaches pending_approval / submitted /
  # rejected (autospec.md §J matrix). Plain contributors who aren't
  # the author never see another user's draft.
  def authorize_view!
    return if @draft.viewable_by?(current_user)

    respond_to do |format|
      format.html { head :forbidden }
      format.json { render json: { error: 'forbidden' }, status: :forbidden }
    end
  end

  # Capabilities the Show view needs to decide which buttons to render.
  # Computed server-side so the view stays a pure function of plain data
  # (no direct access to the User object).
  def draft_capabilities
    {
      can_submit_human: @draft.destination_choosable_by?(current_user, AutospecDraft::DESTINATION_HUMAN),
      can_submit_autodev: @draft.destination_choosable_by?(current_user, AutospecDraft::DESTINATION_AUTODEV),
      can_retract: @draft.retractable_by?(current_user),
      can_vote: @draft.votable_by?(current_user),
      can_edit: @draft.editable_by?(current_user)
    }
  end

  # Votes recorded at the current iteration — shown in the approval
  # banner as an audit trail (who voted what, when). Older iterations'
  # votes stay in the DB but aren't surfaced here.
  def current_iteration_votes
    @draft.autospec_approvals
          .where(iteration: @draft.current_iteration)
          .includes(:user)
          .order(:acted_at)
  end

  def already_voted?
    @draft.autospec_approvals.exists?(user: current_user,
                                      iteration: @draft.current_iteration)
  end

  def render_draft_response
    respond_to do |format|
      format.html { redirect_to "/autospec_drafts/#{@draft.id}" }
      format.json { render json: { draft: serialise_draft(@draft) } }
    end
  end

  # Only fields the editor is allowed to change. `permit` flattens nested
  # meta_chips hash; tags arrive as an array of strings.
  def update_attrs
    params.permit(:title, :markdown, meta_chips: [:type, :priority, { tags: [] }])
          .to_h.symbolize_keys
  end

  def render_apply_error(key, status)
    respond_to do |format|
      format.html { redirect_to "/autospec_drafts/#{@draft.id}", alert: key }
      format.json { render json: { error: key }, status: status }
    end
  end

  def render_apply_result(result)
    respond_to do |format|
      format.html { redirect_to "/autospec_drafts/#{@draft.id}" }
      format.json do
        render json: { draft: serialise_draft(result.draft), fell_back: result.fell_back? }
      end
    end
  end

  def serialise_message(msg)
    { id: msg.id, role: msg.role, content: msg.content, tool_calls: msg.tool_calls }
  end

  def serialise_draft(draft)
    {
      id: draft.id, title: draft.title, markdown: draft.markdown,
      meta_chips: draft.meta_chips, status: draft.status,
      current_iteration: draft.current_iteration,
      preview_html: Autospec::MarkdownRenderer.render(draft.markdown)
    }
  end
end
