# frozen_string_literal: true

# Ported off Sinatra's `get '/projects'` (index) and
# `get '/projects/:slug'` (show). Index: union semantics
# (YAML config + DB-distinct paths), zero-filled placeholder for
# configured-but-quiet projects. Show: decode slug via project_unslug,
# render the same page even for unknown projects (Sinatra parity).
class ProjectsController < ApplicationController # rubocop:disable Metrics/ClassLength
  include ::Web::Helpers

  # GET /projects
  def index
    render html: render_projects_view.html_safe, layout: false
  end

  # GET /projects/:slug
  #
  # Ported from `get '/projects/:slug'` in lib/autodev/web/server.rb.
  # No 404 on missing project (Sinatra parity): an unknown slug still
  # renders the page with empty issues + zero stats + empty config.
  # Non-admin users get 403 on slugs outside their memberships.
  def show
    project_path = project_unslug(params[:slug])
    return head :forbidden unless admin_or_no_session? || visible_project_paths.include?(project_path)

    render html: render_project_show(project_path).html_safe, layout: false
  end

  # GET /projects/new
  #
  # Admin-only form to create a project in the DB (task #9 phase 4 — the
  # replacement for adding a `projects:` entry to config.yml). Renders the
  # same form as #edit on a fresh, unsaved record.
  def new
    return head :forbidden unless can_create_project?

    render html: render_project_edit(Project.new).html_safe, layout: false
  end

  # POST /projects
  #
  # Creates the project from the form. gitlab_path + default_locale come from
  # #project_identity_params (slug/name derived from the path); the per-project
  # config columns from #project_config_params (same field-by-field build as
  # #update — no mass-assignment). On success the membership sync is enqueued
  # so the new project's collaborators populate, then we land on its page.
  def create
    return head :forbidden unless can_create_project?

    project = Project.new
    if project.update(project_identity_params.merge(project_config_params))
      SyncGitlabMembershipsJob.perform_later
      redirect_to "/projects/#{project.slug}?tab=config"
    else
      render html: render_project_edit(project).html_safe, layout: false, status: :unprocessable_entity
    end
  end

  # GET /projects/:slug/edit
  #
  # Per-project config edit form (task #9 phase 3). Gated on project
  # membership/admin like IssuesController#close — editing config is a write to
  # how Autodev runs the project, so only a collaborator (or admin) may do it.
  # Requires a `projects` row to edit (a YAML-only project with no row yet —
  # the soft-transition case — has nothing to edit until the next
  # `autodev:migrate_projects_from_yaml` seeds it), so a missing row is a 404.
  def edit
    project = Project.find_by(gitlab_path: project_unslug(params[:slug]))
    return head :not_found unless project
    return head :forbidden unless can_edit_project?(project)

    render html: render_project_edit(project).html_safe, layout: false
  end

  # PATCH /projects/:slug
  #
  # Persists the edited per-project config onto the projects row. Attributes
  # are built field-by-field by #project_config_params (never mass-assigned
  # from params), so only the known config columns can be written — not
  # gitlab_path/slug/identity. The model carries the validations (phase 1), so
  # an invalid edit re-renders the form with errors (422) instead of saving.
  def update
    project = Project.find_by(gitlab_path: project_unslug(params[:slug]))
    return head :not_found unless project
    return head :forbidden unless can_edit_project?(project)

    if project.update(project_config_params)
      redirect_to "/projects/#{params[:slug]}?tab=config"
    else
      render html: render_project_edit(project).html_safe, layout: false, status: :unprocessable_entity
    end
  end

  private

  # A project's config can be edited by an admin or by a collaborator
  # (contributor or owner) of the project. Mirrors IssuesController#can_close?.
  def can_edit_project?(project)
    return false unless current_user
    return true if current_user.admin?

    current_user.contributor_of?(project)
  end

  # Team tab gating (Autodev #38): who may grant/revoke the manual `owner`
  # role. Narrower than #can_edit_project? — an ordinary contributor can
  # edit the config but must NOT be able to hand out owner. Mirrored (not
  # shared) in ProjectOwnersController, same convention as #can_edit_project?
  # above.
  def can_manage_owners?(project)
    return false unless current_user
    return true if current_user.admin?

    current_user.owner_of?(project)
  end

  # Creating a project is admin-only: a non-admin's access is derived from
  # memberships on existing projects, so there's no project to be a member of
  # before it exists. (Editing an existing one stays open to collaborators.)
  def can_create_project?
    current_user&.admin? || false
  end

  # Identity attributes for a new project: gitlab_path (required) drives the
  # derived slug (`group/x` → `group__x`, same as project_slug / the importer)
  # and a default name (last path segment); default_locale is fr/en. The
  # per-project config columns are added separately by #project_config_params.
  def project_identity_params
    path = params[:gitlab_path].to_s.strip
    {
      gitlab_path: path,
      slug: project_slug(path),
      name: path.split('/').last,
      default_locale: params[:default_locale].presence || 'fr'
    }
  end

  # Builds the attributes hash for #update field-by-field, casting each group
  # by type and normalizing "unset" to nil so a cleared field falls back to the
  # global default (exactly like an absent YAML key): blank string → nil,
  # blank/invalid number → nil, the boolean select's "" → nil (tri-state:
  # unset / true / false), and an empty textarea → nil for the list fields
  # (one entry per line otherwise).
  def project_config_params # rubocop:disable Metrics/AbcSize
    attrs = {}
    Project::CONFIG_STRING_FIELDS.each { |f| attrs[f] = presence_or_nil(params[f]) }
    Project::CONFIG_INTEGER_FIELDS.each { |f| attrs[f] = integer_or_nil(params[f]) }
    Project::BOOLEAN_CONFIG_FIELDS.each { |f| attrs[f] = boolean_or_nil(params[f]) }
    Project::LIST_CONFIG_KEYS.each { |f| attrs[f] = lines_or_nil(params[f]) }
    attrs
  end

  def presence_or_nil(raw)
    value = raw.to_s.strip
    value.empty? ? nil : value
  end

  def integer_or_nil(raw)
    value = raw.to_s.strip
    return nil if value.empty?

    Integer(value, exception: false)
  end

  # Tri-state: the form's <select> offers "" (default/unset), "true", "false".
  def boolean_or_nil(raw)
    case raw.to_s
    when 'true'  then true
    when 'false' then false
    end
  end

  def lines_or_nil(raw)
    items = raw.to_s.split("\n").map(&:strip).reject(&:empty?)
    items.empty? ? nil : items
  end

  def render_project_show(project_path) # rubocop:disable Metrics/MethodLength
    record = Project.find_by(gitlab_path: project_path)
    ::Web::Views::ProjectShow.new(
      project_path: project_path,
      project_config: record ? record.to_project_config : project_for(project_path),
      project_issues: project_issues_for(project_path),
      stats: project_overview_stats(project_path),
      kpis: dashboard_kpis,
      tab: params[:tab].to_s,
      can_edit: record.present? && can_edit_project?(record),
      **team_view_kwargs(record),
      **view_kwargs
    ).call
  end

  # Team tab inputs (Autodev #38): the owners list + candidate contributors
  # for the "add an owner" select, plus the gate for whether to render the
  # management controls at all. Split out of #render_project_show to keep
  # its ABC size down.
  def team_view_kwargs(record)
    {
      team_owners: record ? record.owners.to_a : [],
      team_candidates: record ? record.contributors.to_a : [],
      can_manage_owners: record.present? && can_manage_owners?(record)
    }
  end

  def render_project_edit(project)
    ::Web::Views::ProjectEdit.new(project: project, **view_kwargs).call
  end

  def project_issues_for(project_path)
    issues_dataset.where(project_path: project_path)
                  .order(id: :desc).limit(100).to_a
  end

  def render_projects_view
    ::Web::Views::ProjectsIndex.new(
      projects: projects_with_stats,
      kpis: dashboard_kpis,
      **view_kwargs
    ).call
  end

  # Mirrors the Sinatra block: stats from project_breakdown when the
  # project has issues, zero-filled placeholder otherwise. Order
  # follows all_known_projects (YAML config order then DB-only paths,
  # both alphabetical inside their group).
  def projects_with_stats
    stats_by_path = project_breakdown.to_h { |s| [s[:path], s] }
    all_known_projects.map do |path|
      stats_by_path[path] || { path: path, total: 0, active: 0, done: 0, error: 0 }
    end
  end
end
