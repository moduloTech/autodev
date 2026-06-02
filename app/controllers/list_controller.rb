# frozen_string_literal: true

# Ported off Sinatra's `get '/list/:status'`. One-status filtered
# list of issues, single dataset, single Phlex view.
class ListController < ApplicationController
  include ::Web::Helpers

  # GET /list/:status
  #
  # No allowlist on :status — Sinatra parity. An unknown status simply
  # returns an empty result set (the dataset filter matches nothing).
  def show
    status = params[:status]
    issues = issues_dataset.where(status: status).order(Sequel.desc(:id)).limit(500).all
    html = ::Web::Views::List.new(
      status: status,
      issues: issues,
      locale: web_locale,
      request_path: request.fullpath
    ).call
    render html: html.html_safe, layout: false
  end
end
