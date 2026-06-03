# frozen_string_literal: true

# Static asset serving for the embedded dashboard (cf. autodev/docs/autospec.md
# §D phase B closure). Mirrors the three explicit asset routes that
# lib/autodev/web/server.rb still defines for the standalone `bin/autodev`
# Sinatra entry point — same URL space, same filesystem source, same
# content-type / cache-control headers — so the Phlex layout's
# `<link href="/assets/css/...">` and `<script src="/assets/turbo.js">`
# tags resolve identically whether requests hit `bin/rails server` or
# `bin/autodev`.
#
# The files live under `lib/autodev/web/public/` (single source of truth).
# Propshaft / Sprockets is intentionally NOT wired here — attack-order step 8
# replaces this controller with the Rails asset pipeline + Phlex view port
# during phase C. Until then, two routes serving the same bytes from two
# entry points is acceptable cost.
class AssetsController < ApplicationController
  # Rails' `protect_from_forgery` includes a cross-origin JavaScript guard
  # (`X-Requested-With` check) that returns 422 for `<script src>` requests
  # without a matching Referer — turbo.js loaded by an embedded dashboard
  # served on a different host would be blocked. Static, public, read-only
  # assets don't need that protection, so opt out on this controller.
  skip_forgery_protection

  ASSETS_ROOT = File.expand_path('../../lib/autodev/web/public', __dir__).freeze

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
