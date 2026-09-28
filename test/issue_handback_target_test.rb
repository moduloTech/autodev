# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'

# `Issue#handback_target` — the one definition of who gets a ticket back
# (Autodev #98, moved onto the model by Autodev #126 so the dashboard's Clore and
# a label handover read the same rule as `IssueNotifier`). The person autodev
# displaced comes first: handing their ticket to its author moves it to somebody
# who never had it.
class IssueHandbackTargetTest < Minitest::Test
  include DatabaseTestHelper

  def setup
    setup_database
  end

  def target(displaced, author)
    create_issue(displaced_assignee_id: displaced, issue_author_id: author).handback_target
  end

  def test_the_displaced_assignee_wins_over_the_author
    assert_equal 55, target(55, 42)
  end

  def test_the_author_is_the_answer_when_nobody_was_displaced
    assert_equal 42, target(nil, 42)
  end

  def test_nobody_is_the_answer_when_neither_is_known
    assert_nil target(nil, nil)
  end
end
