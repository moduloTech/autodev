# frozen_string_literal: true

# Static asset serving for the embedded dashboard and any Rails engine mounted
# under it (Mission Control — Jobs in particular). A single catch-all route
# `/assets/*path` resolves via Propshaft's load_path so we get one consistent
# handler whether the URL is digested (MCJ's `application-<sha>.css`) or
# stable (`/assets/css/tokens.css` from our Phlex layout).
#
# Why not just let `Propshaft::Server` (the middleware Propshaft auto-inserts
# in dev) handle this? Two reasons:
#
#  1. The middleware demands a digest in the URL — its `Asset#fresh?(nil)`
#     returns false, so stable URLs like `/assets/css/tokens.css` 404 with a
#     bare "Not found" body before reaching the router. Our Phlex layout
#     hardcodes those URLs intentionally (cf. the original comment on this
#     controller: "the asset URL space stays stable across the supervisor
#     topology"), so the dev-default middleware breaks our own pages.
#
#  2. Production already runs without `Propshaft::Server` — Rails 8 only
#     inserts it when `RAILS_SERVE_STATIC_FILES` is set, and it isn't. So
#     prod has always served `/assets/*` through this controller via the
#     router. Dropping the middleware in dev too keeps both environments on
#     the same code path.
#
# We still keep Propshaft's railtie loaded — MCJ depends on
# `config.assets.paths` being available at boot, and the load_path machinery
# is what this controller looks assets up in.
class AssetsController < ApplicationController
  # Rails' `protect_from_forgery` includes a cross-origin JavaScript guard
  # (`X-Requested-With` check) that returns 422 for `<script src>` requests
  # without a matching Referer — turbo.js loaded by an embedded dashboard
  # served on a different host would be blocked. Static, public, read-only
  # assets don't need that protection, so opt out on this controller.
  skip_forgery_protection

  # Static assets are intentionally public: the Entra ID redirect page +
  # any future unauthenticated screens still need CSS/fonts/turbo.js to
  # render. PR3 of the users-rollout chantier (cf. docs/users-rollout.md §4).
  skip_before_action :authenticate_user!, raise: false

  # Catch-all action: `/assets/<logical-path-maybe-with-digest>`.
  # Strips any propshaft-style `-<sha>` digest from the basename before
  # looking the asset up by its logical path in Propshaft's load_path
  # (`app/assets/static/*`, MCJ's `app/assets/stylesheets/*`, vendored
  # turbo/stimulus, etc.). Emits `asset.compiled_content` so CSS that
  # references other assets via `url()` gets the propshaft compilers'
  # digest-aware rewriting — matching the body Propshaft::Server would
  # produce, minus the digest-required gate.
  def show
    asset = find_asset
    return head :not_found unless asset

    response.headers['Cache-Control'] = cache_control_for(asset)
    send_data asset.compiled_content,
              type: asset.content_type_with_charset.to_s,
              disposition: 'inline'
  end

  private

  def find_asset
    logical_path, _digest = Propshaft::Asset.extract_path_and_digest(params[:path].to_s)
    Rails.application.assets.load_path.find(logical_path)
  end

  # Fingerprinted URLs (e.g. MCJ's `application-<sha>.css`) get the standard
  # propshaft `immutable` cache header — the digest changes when contents do,
  # so the browser can cache aggressively. Stable URLs from our layout (e.g.
  # `/assets/css/tokens.css`) get `no-cache` so dev edits show up without a
  # hard refresh; the browser still 304s on unchanged bytes via ETag.
  def cache_control_for(asset)
    digested_in_url = params[:path].to_s != asset.logical_path.to_s
    digested_in_url ? 'public, max-age=31536000, immutable' : 'no-cache'
  end
end
