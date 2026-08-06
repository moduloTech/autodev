# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'

# Autodev #46 point 3 — a Claude quota outage used to live in the log only, so
# nobody could tell a paused autodev from a broken one. It now shows on `/` for
# every signed-in user: the pause holds up everyone's tickets, not just admins'.
class DashboardUsagePausedBannerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  BANNER = 'Quota Claude épuisé'

  setup do
    @admin  = User.create!(email: 'admin@modulotech.fr', name: 'Admin', admin: true)
    @member = User.create!(email: 'member@modulotech.fr', name: 'Member')
    Project.create!(gitlab_path: 'group/mine', slug: 'group__mine')
    ProjectMembership.create!(user: @member,
                              project: Project.find_by(gitlab_path: 'group/mine'),
                              role: 'contributor')
  end

  def usage_event(available:, age_seconds: 0)
    ActivityEvent.create!(
      issue_id: nil, kind: 'usage', level: available ? 'info' : 'warn',
      payload_json: JSON.generate(available: available),
      created_at: Time.now.utc - age_seconds
    )
  end

  def test_member_sees_the_banner_when_the_quota_is_exhausted
    usage_event(available: false)
    sign_in @member
    get '/'

    assert_includes response.body, BANNER
  end

  def test_admin_sees_the_banner_too
    usage_event(available: false)
    sign_in @admin
    get '/'

    assert_includes response.body, BANNER
  end

  # The copy must say what still works, or the banner reads as "autodev is down".
  def test_the_banner_says_tracking_keeps_running
    usage_event(available: false)
    sign_in @member
    get '/'

    assert_includes response.body, 'suivi des pipelines'
  end

  def test_no_banner_when_the_quota_is_available
    usage_event(available: true)
    sign_in @member
    get '/'

    refute_includes response.body, BANNER
  end

  def test_no_banner_when_nothing_was_ever_probed
    sign_in @member
    get '/'

    refute_includes response.body, BANNER
  end

  def test_no_banner_on_a_stale_verdict
    usage_event(available: false, age_seconds: 5_000)
    sign_in @member
    get '/'

    refute_includes response.body, BANNER
  end
end
