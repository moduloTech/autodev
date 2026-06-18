# frozen_string_literal: true

require_relative 'autodev_test_helper'

# Coverage for the manual-close feature at the model + helper layer: the AASM
# `close` event (terminal `closed` state), its exclusion from the generic
# transition dropdown, and the "Clôs" tab filter.
class IssueCloseTest < Minitest::Test
  include DatabaseTestHelper

  class Host
    include ::Web::Helpers
  end

  def setup
    setup_database
    @helper = Host.new
  end

  def test_close_from_an_active_state
    issue = create_issue(status: 'implementing')

    assert_predicate issue, :may_close?
    issue.close!

    assert_equal 'closed', issue.status
  end

  def test_close_from_done
    issue = create_issue(status: 'done')
    issue.close!

    assert_equal 'closed', issue.status
  end

  def test_closed_is_terminal
    issue = create_issue(status: 'closed')

    refute_predicate issue, :may_close?
  end

  def test_permitted_events_excludes_close
    issue = create_issue(status: 'pending')

    assert_predicate issue, :may_close?, 'close is a valid AASM event from pending'
    refute_includes @helper.permitted_events_for(issue), :close, 'but it must not appear in the generic dropdown'
  end

  def test_closed_tab_filters_only_closed
    create_issue(status: 'closed')
    create_issue(status: 'done')

    rows = @helper.apply_tab(@helper.issues_dataset, 'closed').to_a

    assert_equal ['closed'], rows.map(&:status)
  end

  def test_tab_counts_includes_closed
    2.times { create_issue(status: 'closed') }

    assert_equal 2, @helper.tab_counts[:closed]
  end
end
