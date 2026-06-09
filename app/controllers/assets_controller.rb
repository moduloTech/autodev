# frozen_string_literal: true

# Static asset serving for the embedded dashboard. Three explicit routes
# under `/assets/*` send the vendored Turbo build, the three CSS files,
# and the WOFF2 webfonts from `app/assets/static/`. Routes are explicit
# (rather than Rails' propshaft pipeline) because the asset URL space
# stays stable across the supervisor topology and the Phlex layout's
# `<link href="/assets/css/...">` / `<script src="/assets/turbo.js">`
# tags do not need to know about asset digests.
class AssetsController < ApplicationController
  # Rails' `protect_from_forgery` includes a cross-origin JavaScript guard
  # (`X-Requested-With` check) that returns 422 for `<script src>` requests
  # without a matching Referer — turbo.js loaded by an embedded dashboard
  # served on a different host would be blocked. Static, public, read-only
  # assets don't need that protection, so opt out on this controller.
  skip_forgery_protection

  ASSETS_ROOT = Rails.root.join('app/assets/static').to_s.freeze

  # Vendored Turbo build (no CDN dependency). One file, fixed URL.
  def turbo_js
    send_file File.join(ASSETS_ROOT, 'turbo.js'),
              type: 'application/javascript',
              disposition: 'inline'
  end

  # Stylesheets under public/css/. `no-cache` so dev edits don't require a
  # manual cache-bust (the browser still 304s on unchanged bytes).
  def css
    path = File.join(ASSETS_ROOT, 'css', "#{params[:name]}.css")
    return head :not_found unless File.file?(path)

    response.headers['Cache-Control'] = 'no-cache'
    send_file path, type: 'text/css', disposition: 'inline'
  end

  # Vendored web fonts (Inter, JetBrains Mono). Names are opaque hashes
  # from Google Fonts — the constraint at the route level pins them to
  # `[A-Za-z0-9_-]+`, so the filesystem lookup is safe.
  def font
    path = File.join(ASSETS_ROOT, 'vendor', 'fonts', "#{params[:name]}.woff2")
    return head :not_found unless File.file?(path)

    response.headers['Cache-Control'] = 'public, max-age=31536000, immutable'
    send_file path, type: 'font/woff2', disposition: 'inline'
  end
end
