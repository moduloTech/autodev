# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'

# Admin-only setup warning on `/` when the Anthropic API key isn't
# configured (cf. Web::Views::Dashboard#render_anthropic_missing_banner).
# Non-admin users never see it — they can't fix the key.
class DashboardAnthropicBannerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin  = User.create!(email: 'admin@modulotech.fr', name: 'Admin', admin: true)
    @member = User.create!(email: 'member@modulotech.fr', name: 'Member')
    Project.create!(gitlab_path: 'group/mine', slug: 'group__mine')
    ProjectMembership.create!(user: @member,
                              project: Project.find_by(gitlab_path: 'group/mine'),
                              role: 'contributor')
    @previous_env_key = ENV.delete('ANTHROPIC_API_KEY')
    Autospec::Chat.default_client = nil
  end

  teardown do
    ENV['ANTHROPIC_API_KEY'] = @previous_env_key if @previous_env_key
    Autospec::Chat.default_client = nil
  end

  def test_admin_sees_banner_when_key_missing
    sign_in @admin
    get '/'

    assert_includes response.body, 'Clé Anthropic manquante'
  end

  def test_member_does_not_see_banner_when_key_missing
    sign_in @member
    get '/'

    refute_includes response.body, 'Clé Anthropic manquante'
  end

  def test_admin_does_not_see_banner_when_key_configured
    Autospec::Chat.default_client = Object.new # any truthy value → "configured"
    sign_in @admin
    get '/'

    refute_includes response.body, 'Clé Anthropic manquante'
  end
end
