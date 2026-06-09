# frozen_string_literal: true

# Configuration for the Mission Control — Jobs dashboard (mounted at
# /admin/jobs by config/routes.rb).
#
# PR3 of the users-rollout chantier (alpha.7+) gates the whole dashboard
# behind Microsoft 365 SSO. We override Mission Control's base controller
# so its controllers inherit our `AdminApplicationController` chain:
# authenticate_user! → require_admin. The gem's HTTP Basic Auth gate
# stays off — Devise + admin? handles it now.
MissionControl::Jobs.http_basic_auth_enabled = false
MissionControl::Jobs.base_controller_class = '::AdminApplicationController'

# Without explicit `applications`, Mission Control inspects the default
# ActiveJob queue adapter — which is Solid Queue here (set in
# config/application.rb). One queue DB, no special wiring needed.
