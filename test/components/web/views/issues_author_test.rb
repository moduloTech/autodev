# frozen_string_literal: true

require_relative '../../../autodev_test_helper'

# Task #27: every issues tab must show the ticket author's name so a user can
# spot their own requests at a glance — in the dense desktop table, the mobile
# stacked cards, and the "needs-a-human" watch cards (errors/waiting/
# delivered_review).
class IssuesAuthorTest < ActiveSupport::TestCase
  include DatabaseTestHelper

  def setup
    setup_database
  end

  def render_tab(issue, tab)
    Web::Views::Issues.new(
      issues: [issue], total: 1, total_pages: 1, page: 1, per_page: 50,
      filters: {}, tab: tab, tab_counts: Hash.new(0),
      kpis: Hash.new(0), closable_ids: Set.new
    ).call
  end

  def test_table_and_cards_show_author_name
    issue = create_issue(status: 'pending', issue_author_name: 'Jean Dupont', issue_author_id: 7)
    html = render_tab(issue, 'all')

    # Rendered once in the desktop table row meta and once in the mobile card.
    assert_equal 2, html.scan('Jean Dupont').size
  end

  def test_watch_card_shows_author_name
    issue = create_issue(status: 'error', error_message: 'boom',
                         issue_author_name: 'Marie Curie', issue_author_id: 9)
    html = render_tab(issue, 'errors')

    assert_includes html, 'Marie Curie'
  end

  def test_falls_back_to_author_id_when_name_missing
    issue = create_issue(status: 'error', error_message: 'boom', issue_author_id: 42)
    html = render_tab(issue, 'errors')

    assert_includes html, '#42'
  end
end
