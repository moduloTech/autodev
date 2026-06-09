# frozen_string_literal: true

# Rails-native controller for routes ported off Sinatra. Sinatra still
# answers any route not declared above the catch-all `mount Web::Server`
# in config/routes.rb.
class IssuesController < ApplicationController
  # Web::Helpers is the same module Sinatra mixes into Web::Server via
  # `helpers Web::Helpers`. Pulled in here so we can call find_issue,
  # activity_events_dataset, dashboard_kpis, web_locale, etc. with
  # identical semantics. Helpers that touch request.cookies / response
  # are Rack-compatible (they go through ActionDispatch's Rack layer).
  include ::Web::Helpers

  # Forms in the embedded dashboard are rendered by Phlex (the same
  # views Sinatra serves) and do NOT emit a CSRF token — the Sinatra
  # side has no CSRF protection. Until the views are ported to Rails
  # and the layout starts emitting `csrf_meta_tags`, write actions
  # opt out of CSRF rather than 422 every form submission. The
  # opt-out is scoped per-action so we don't accidentally disable
  # protection on something that doesn't strictly need to.
  skip_forgery_protection only: %i[reset transition]

  # GET /issues
  #
  # Ported from `get '/issues'` in lib/autodev/web/server.rb. Paginated,
  # filterable list. All helpers (per_page_for, page_for, filter_issues,
  # paginate, tab_param, tab_counts) live in Web::Helpers::IssuesFilter
  # and consume `params` via bracket access — Rails' ActionController
  # ::Parameters satisfies that contract.
  def index
    render html: render_issues_index.html_safe, layout: false
  end

  # GET /issues/:id
  # GET /issues/:id.json
  #
  # Both formats land here; respond_to dispatches. The Phlex view consumes
  # a symbol-keyed hash (Sinatra/Sequel legacy contract), so we hand it
  # `issue_model.attributes.symbolize_keys` rather than the AR record.
  def show
    issue_model = find_issue(params[:id])
    return head :not_found unless issue_model

    respond_to do |format|
      format.html { render html: render_issue_show(issue_model).html_safe, layout: false }
      format.json { render json: issue_model.attributes }
    end
  end

  # POST /issues/:id/reset
  #
  # Ported from `post %r{/issues/(\\d+)/reset}` in lib/autodev/web/server.rb.
  # NOT an AASM transition — raw SQL UPDATE that clears retry/error state
  # and forces status back to 'pending'. The Sinatra version does the same;
  # we match it byte-for-byte. After-transition hooks intentionally do NOT
  # fire (this is a recovery action, not a normal flow event). The audit row
  # is written directly from here for that reason.
  def reset # rubocop:disable Metrics/MethodLength
    issue = find_issue(params[:id])
    return head :not_found unless issue

    previous_state = issue.status
    Issue.where(id: issue.id).update_all(
      status: 'pending', retry_count: 0, error_message: nil,
      next_retry_at: nil, started_at: nil
    )
    Audit.record!(
      resource: issue, action: 'issue.reset_manual', actor: current_user,
      payload: { project_path: issue.project_path, iid: issue.issue_iid, previous_state: previous_state }
    )
    redirect_to "/issues/#{issue.id}"
  end

  # POST /issues/:id/transition?event=<aasm_event>
  #
  # Ported from `post %r{/issues/(\\d+)/transition}` in lib/autodev/web/server.rb.
  # This DOES go through AASM (unlike #reset) — `issue.send("\#{event}!")` fires
  # the corresponding `event!` method on the Sequel model, which triggers the
  # after_all_transitions hooks defined in lib/autodev/issue_behavior.rb:80
  # (`persist_status_change!` saves the row, `emit_activity_event!` inserts a
  # transition row in activity_events). We trust those hooks to do their job;
  # the controller only enforces the "permitted event" guard, same as Sinatra.
  def transition # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
    issue = find_issue(params[:id])
    return head :not_found unless issue

    event = params[:event].to_s
    unless permitted_events_for(issue).include?(event.to_sym)
      return render plain: "Event '#{event}' not permitted from #{issue.status}",
                    status: :unprocessable_entity
    end

    issue._audit_actor = current_user
    issue._audit_origin = :manual
    issue.send("#{event}!")
    redirect_to "/issues/#{issue.id}"
  end

  private

  def render_issues_index
    per_page = per_page_for(params)
    issues, total, total_pages, page = paginate(filter_issues(params), page_for(params), per_page)
    ::Web::Views::Issues.new(
      **pagination_kwargs(issues, total, total_pages, page,
                          per_page), **filters_kwargs, locale: web_locale, request_path: request.fullpath
    ).call
  end

  def pagination_kwargs(issues, total, total_pages, page, per_page)
    { issues: issues, total: total, total_pages: total_pages,
      page: page, per_page: per_page }
  end

  def filters_kwargs
    { filters: { q: params[:q], from: params[:from], to: params[:to] },
      tab: tab_param(params), tab_counts: tab_counts,
      kpis: dashboard_kpis }
  end

  def render_issue_show(issue_model)
    ::Web::Views::IssueShow.new(
      issue: issue_model.attributes.symbolize_keys,
      issue_model: issue_model,
      events: events_for(issue_model),
      kpis: dashboard_kpis,
      locale: web_locale,
      request_path: request.fullpath
    ).call
  end

  def events_for(issue_model)
    activity_events_dataset.where(issue_id: issue_model.id)
                           .order(created_at: :desc, id: :desc)
                           .limit(200).to_a
  end
end
