# frozen_string_literal: true

require_relative '../rails_helper'

# Wiring test — `SyncGitlabMembershipsJob#perform` should call
# `GitlabMembershipSync.for_all_users!` and pass through a JobLogger.
class SyncGitlabMembershipsJobTest < ActiveSupport::TestCase
  def test_perform_calls_sync_for_all_users
    called = false
    ::Autodev::GitlabMembershipSync.stub(:for_all_users!, ->(**_kw) { called = true }) do
      SyncGitlabMembershipsJob.new.perform
    end

    assert called
  end

  def test_perform_wraps_logger_as_job_logger
    captured_logger = nil
    stub = lambda do |**kw|
      captured_logger = kw[:logger]
    end
    ::Autodev::GitlabMembershipSync.stub(:for_all_users!, stub) do
      SyncGitlabMembershipsJob.new.perform
    end

    assert_kind_of ::Autodev::JobLogger, captured_logger
  end
end
