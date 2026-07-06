# frozen_string_literal: true

require_relative '../../autodev_test_helper'
require 'ostruct'

# find_or_create_issue must capture the GitLab author's display name (task #27),
# not just the numeric id, so the dashboard can show who filed each request.
class PollDispatcherAuthorTest < ActiveSupport::TestCase
  include DatabaseTestHelper

  def setup
    setup_database
  end

  def dispatcher
    Autodev::PollDispatcher.new(
      config: { 'gitlab_url' => 'https://gitlab.example.com', 'gitlab_token' => 'x' },
      project_config: { 'path' => 'group/project' },
      logger: StubLogger.new
    )
  end

  def gl_issue(author:)
    OpenStruct.new(iid: 42, title: 'Something to fix', description: 'Please fix this bug.', # rubocop:disable Style/OpenStructUse
                   author: author)
  end

  def test_persists_author_name_and_id
    author = OpenStruct.new(id: 7, name: 'Jean Dupont', username: 'jdupont') # rubocop:disable Style/OpenStructUse
    dispatcher.send(:find_or_create_issue, gl_issue(author: author))

    issue = Issue.find_by(project_path: 'group/project', issue_iid: 42)

    assert_equal 'Jean Dupont', issue.issue_author_name
    assert_equal 7, issue.issue_author_id
  end

  def test_handles_missing_author
    dispatcher.send(:find_or_create_issue, gl_issue(author: nil))

    issue = Issue.find_by(project_path: 'group/project', issue_iid: 42)

    assert_nil issue.issue_author_name
    assert_nil issue.issue_author_id
  end
end
