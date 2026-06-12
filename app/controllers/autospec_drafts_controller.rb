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
class AutospecDraftsController < ApplicationController
  include ::Web::Helpers

  before_action :load_draft, except: %i[index new create]
  before_action :authorize_author!, except: %i[index new create]

  rescue_from Autospec::SuggestionApplier::AlreadyApplied,
              with: -> { render_apply_error('already_applied', :conflict) }
  rescue_from Autospec::SuggestionApplier::ToolUseNotFound,
              with: -> { render_apply_error('tool_use_not_found', :not_found) }
  rescue_from Autospec::SuggestionApplier::UnsupportedTool,
              with: -> { render_apply_error('unsupported_tool', :unprocessable_entity) }

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

  # GET /autospec_drafts/:id
  def show
    render html: Web::Views::AutospecDrafts::Show.new(
      draft: @draft, messages: @draft.autospec_messages.order(:id), **view_kwargs
    ).call.html_safe, layout: false
  end

  # POST /autospec_drafts/:id/chat
  def chat
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
      current_iteration: draft.current_iteration
    }
  end
end
