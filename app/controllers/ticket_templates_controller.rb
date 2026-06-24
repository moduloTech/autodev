# frozen_string_literal: true

# Per-project ticket templates CRUD (task #14). A project may define
# several named templates (e.g. "évolution", "bug") whose markdown body
# becomes the structure AutoSpec follows when a ticket is drafted on that
# project — replacing the manual copy-paste of a template into the chat.
#
# Gated exactly like the per-project config edit (ProjectsController#edit):
# admin, or a collaborator (contributor/owner) of the project. The project
# is resolved by slug; a missing `projects` row is a 404 (same rule as the
# config editor — there's nothing to attach templates to yet).
class TicketTemplatesController < ApplicationController
  include ::Web::Helpers

  before_action :load_project
  before_action :authorize_editor!
  before_action :load_template, only: %i[edit update destroy]

  # GET /projects/:slug/ticket_templates
  def index
    render_view(::Web::Views::TicketTemplates::Index, templates: @project.ticket_templates.to_a)
  end

  # GET /projects/:slug/ticket_templates/new
  def new
    render_view(::Web::Views::TicketTemplates::Form, template: @project.ticket_templates.new)
  end

  # POST /projects/:slug/ticket_templates
  def create
    template = @project.ticket_templates.create(template_params)
    if template.persisted?
      redirect_to templates_path
    else
      render_view(::Web::Views::TicketTemplates::Form, template: template, status: :unprocessable_entity)
    end
  end

  # GET /projects/:slug/ticket_templates/:id/edit
  def edit
    render_view(::Web::Views::TicketTemplates::Form, template: @template)
  end

  # PATCH /projects/:slug/ticket_templates/:id
  def update
    if @template.update(template_params)
      redirect_to templates_path
    else
      render_view(::Web::Views::TicketTemplates::Form, template: @template, status: :unprocessable_entity)
    end
  end

  # DELETE /projects/:slug/ticket_templates/:id
  def destroy
    @template.destroy
    redirect_to templates_path
  end

  private

  def load_project
    @project = Project.find_by(gitlab_path: project_unslug(params[:slug]))
    head :not_found unless @project
  end

  def authorize_editor!
    head :forbidden unless can_edit_project?(@project)
  end

  def load_template
    @template = @project.ticket_templates.find_by(id: params[:id])
    head :not_found unless @template
  end

  # Same gate as ProjectsController#can_edit_project? — admin or a
  # collaborator of the project.
  def can_edit_project?(project)
    return false unless current_user
    return true if current_user.admin?

    current_user.contributor_of?(project)
  end

  # Only name + slug + body are user-set. The slug comes from `template_slug`
  # (not `slug`, which the route already binds to the project's slug); an
  # omitted/blank one is dropped so the model derives it from the name.
  def template_params
    { name: params[:name].to_s.strip,
      slug: params[:template_slug].to_s.strip.presence,
      body: params[:body].to_s }.compact
  end

  def templates_path
    "/projects/#{params[:slug]}/ticket_templates"
  end

  def render_view(klass, status: :ok, **)
    html = klass.new(project: @project, **, **view_kwargs).call
    render html: html.html_safe, layout: false, status: status
  end
end
