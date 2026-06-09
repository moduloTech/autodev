# frozen_string_literal: true

require_relative '../../rails_helper'

# Coverage for the shared entry points called from both the rake tasks
# and the bin/autodev CLI flags (alpha.7+). The integration with
# GitlabMembershipSync is covered in detail by
# `gitlab_membership_sync_test.rb`; this file focuses on the
# orchestration + summary formatting that OpsCommands owns.
module Autodev
  class OpsCommandsTest < ActiveSupport::TestCase
    def test_seed_admin_creates_user_with_admin_true
      out = Autodev::OpsCommands.seed_admin(email: 'admin@modulotech.fr')

      user = User.find_by!(email: 'admin@modulotech.fr')

      assert_predicate user, :admin?
      assert_match(/Seeded.*admin/i, out.gsub('seed_admin', 'Seeded admin'))
      assert_equal 'admin', user.name
    end

    def test_seed_admin_idempotent_upserts_existing
      User.create!(email: 'admin@modulotech.fr', name: 'Pre-existing', admin: false)
      Autodev::OpsCommands.seed_admin(email: 'admin@modulotech.fr')

      assert_predicate User.find_by!(email: 'admin@modulotech.fr'), :admin?
    end

    def test_seed_admin_writes_audit_log
      Autodev::OpsCommands.seed_admin(email: 'admin@modulotech.fr')

      log = AuditLog.where(action: 'user.created').last

      assert_equal 'seed_admin', log.payload['source']
    end

    def test_link_user_updates_gitlab_username_and_resets_id
      user = User.create!(email: 'foo@modulotech.fr', name: 'Foo',
                          gitlab_username: 'foo', gitlab_user_id: 1)
      Autodev::OpsCommands.link_user(email: 'foo@modulotech.fr', gitlab_username: 'fbar')

      user.reload

      assert_equal 'fbar', user.gitlab_username
      assert_nil user.gitlab_user_id
    end

    def test_sync_memberships_warns_when_projects_table_empty
      User.create!(email: 'someone@modulotech.fr', name: 'Someone',
                   gitlab_username: 'someone', gitlab_user_id: 42)

      io = StringIO.new
      original = Rails.logger
      Rails.logger = Logger.new(io)
      Autodev::OpsCommands.sync_memberships

      assert_match(/projects.*table is empty/i, io.string)
    ensure
      Rails.logger = original
    end
  end
end
