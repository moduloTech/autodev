# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # Phase B: no allow_browser filter yet — the legacy Sinatra Web::Server
  # serves arbitrary clients (curl, scripts, the embedded SSE dashboard
  # running across a NetBird mesh) without a User-Agent check, and we
  # must not regress that contract as routes are ported. A modern-browser
  # policy can be reintroduced once the route porting completes and we
  # consciously decide which endpoints need it.
end
