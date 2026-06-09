# frozen_string_literal: true

# Configuration for the Mission Control — Jobs dashboard (mounted at
# /admin/jobs by config/routes.rb).
#
# We turn off the gem's built-in HTTP Basic Auth gate for v1.0.0-alpha.x:
# autodev binds to 127.0.0.1 by default and access is mediated by the
# user's NetBird/Tailscale mesh, the same trust model the rest of the
# dashboard runs under. Re-enable with `http_basic_auth_user` +
# `http_basic_auth_password` (or use Devise `authenticate_user!` in the
# host app once Entra ID is gating the Phlex dashboard too).
MissionControl::Jobs.http_basic_auth_enabled = false

# Without explicit `applications`, Mission Control inspects the default
# ActiveJob queue adapter — which is Solid Queue here (set in
# config/application.rb). One queue DB, no special wiring needed.
