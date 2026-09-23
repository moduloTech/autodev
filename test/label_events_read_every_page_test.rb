# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'
require_relative 'gitlab_pages'
require 'autodev/gitlab_helpers'

# `LabelHandover#events` read one page of a ticket's resource label events, and
# the page it read was the wrong one (Autodev #116).
#
# `issue_label_events` takes no options in gitlab-5.1.0, so it answers GitLab's
# default page of 20 — and the endpoint lists events oldest first. Every
# consumer wants the newest: `last_event_for` takes the last event naming a
# label as the edit that produced the state just read, `todo_reapplied_after?`
# looks for a todo label added after the row was closed. Past twenty events both
# read history that has since been overwritten, with no error and no signal.
#
# Not a corner case: on 23/09/2026, 86 of the 142 tracked tickets carried more
# than twenty label events (max 64). powerpanne/core#15673 carries 35; the todo
# label a human reposed on 21/08/2026 at 10:26:54 UTC, after autodev closed the
# row at 07:52:03, is on page 2, and the reentry gate answered false on every
# cycle for a month.
#
# Every history here is built by `GitlabPagesClient`, a real `Gitlab::Client`
# whose only replaced part is the HTTP `get`, so what walks the pages is the
# gem's own `auto_paginate`.
class LabelEventsReadEveryPageTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  include DatabaseTestHelper

  AUTODEV_ID = 7
  HUMAN_ID = 999
  PAGE = 20

  POWERPANNE = {
    'labels_todo' => ['To Do'],
    'label_doing' => 'Development::Doing',
    'label_done' => 'Development::Awaiting Feature Review'
  }.freeze

  FakeUser = Struct.new(:id)
  FakeLabel = Struct.new(:name)
  FakeEvent = Struct.new(:action, :label, :user, :created_at)
  FakeIssue = Struct.new(:labels)

  def setup
    setup_database
    GitlabHelpers.instance_variable_set(:@current_user_id, AUTODEV_ID)
  end

  def ev(action, name, user_id, at)
    FakeEvent.new(action, FakeLabel.new(name), FakeUser.new(user_id), at)
  end

  # Filler naming a label none of the assertions look at, so that the events
  # the test is about sit exactly where it puts them.
  def noise(count, at: '2026-03-17T08:00:00Z')
    Array.new(count) { ev('add', 'PM::Evolution', HUMAN_ID, at) }
  end

  def handover(client)
    Autodev::LabelHandover.new(client: client, path: 'group/project',
                               project_config: POWERPANNE, logger: StubLogger.new)
  end

  # --- the reentry gate: the #15673 shape --------------------------------

  FINISHED_AT = Time.utc(2026, 8, 21, 7, 52, 3)

  # Page 1 ends on the todo label being *removed* on 12/08, before the close;
  # the human's re-add of 21/08 is on page 2. The first page alone says nobody
  # asked again.
  def test_a_todo_label_reposed_on_the_second_page_reopens_a_closed_row
    page_one = noise(PAGE - 2) + [ev('add', 'To Do', HUMAN_ID, '2026-08-12T10:31:00Z'),
                                  ev('remove', 'To Do', AUTODEV_ID, '2026-08-12T10:32:00Z')]
    page_two = [ev('add', 'To Do', HUMAN_ID, '2026-08-21T10:26:54Z')] + noise(14, at: '2026-08-21T10:30:00Z')
    client = GitlabPagesClient.new([page_one, page_two])

    assert handover(client).todo_reapplied_after?(15_673, FINISHED_AT),
           'the re-add after finished_at is on page 2 and must be seen'
    assert_equal [1, 2], client.fetched
  end

  # --- authorship: the last event is on the last page --------------------

  # A human posed the end label long ago (page 1); autodev re-posed it later,
  # after a reentry and a second delivery (page 2). Reading page 1 alone
  # attributes the current label to the human — and closes a live ticket with a
  # comment blaming them.
  def test_the_end_label_reposed_by_autodev_on_a_later_page_is_not_a_handover
    label = POWERPANNE['label_done']
    page_one = noise(PAGE - 1) + [ev('add', label, HUMAN_ID, '2026-05-02T09:00:00Z')]
    page_two = [ev('remove', label, AUTODEV_ID, '2026-06-01T09:00:00Z'),
                ev('add', label, AUTODEV_ID, '2026-06-20T09:00:00Z')]

    assert_nil handover(GitlabPagesClient.new([page_one, page_two])).verdict(FakeIssue.new([label]), 42)
  end

  # The reverse: autodev's own add closes page 1, the human's is on page 2.
  # Reading page 1 alone answers "autodev did it" and the handover is missed.
  def test_the_end_label_posed_by_a_human_on_a_later_page_is_a_handover
    label = POWERPANNE['label_done']
    page_one = noise(PAGE - 2) + [ev('add', label, AUTODEV_ID, '2026-05-02T09:00:00Z'),
                                  ev('remove', label, AUTODEV_ID, '2026-05-03T09:00:00Z')]
    page_two = [ev('add', label, HUMAN_ID, '2026-06-20T09:00:00Z')]

    verdict = handover(GitlabPagesClient.new([page_one, page_two])).verdict(FakeIssue.new([label]), 42)

    assert_equal :done_added, verdict&.reason
  end

  # Two pages would also be satisfied by a read that stops after two — or after
  # forty events. The measured maximum is 64, four pages; in the three tests
  # below only page 3 carries the deciding event, once per consumer.
  def three_pages(last)
    [noise(PAGE), noise(PAGE - 1) + [ev('add', POWERPANNE['label_done'], AUTODEV_ID, '2026-05-02T09:00:00Z')], last]
  end

  def human_done_on_page_three
    GitlabPagesClient.new(three_pages([ev('add', POWERPANNE['label_done'], HUMAN_ID, '2026-06-20T09:00:00Z')]))
  end

  def test_the_reentry_gate_walks_to_the_last_page_whatever_their_number
    client = GitlabPagesClient.new(three_pages([ev('add', 'To Do', HUMAN_ID, '2026-08-21T10:26:54Z')]))

    assert handover(client).todo_reapplied_after?(15_673, FINISHED_AT)
    assert_equal [1, 2, 3], client.fetched
  end

  def test_a_verdict_walks_to_the_last_page_whatever_their_number
    verdict = handover(human_done_on_page_three).verdict(FakeIssue.new([POWERPANNE['label_done']]), 42)

    assert_equal :done_added, verdict&.reason
  end

  def test_moved_since_walks_to_the_last_page_whatever_their_number
    assert handover(human_done_on_page_three)
      .moved_since?(FakeIssue.new([POWERPANNE['label_done']]), 42, Time.utc(2026, 6, 1))
  end

  # `moved_since?` — `UntouchedSinceGiveup`'s question — through the same walk:
  # autodev's own add closes page 1, before the give-up; a human's later add
  # is on page 2. Page 1 alone answers "untouched", i.e. permission to take the
  # ticket from the person holding it.
  def test_a_label_moved_after_the_give_up_on_a_later_page_is_seen_by_moved_since
    label = POWERPANNE['label_done']
    page_one = noise(PAGE - 1) + [ev('add', label, AUTODEV_ID, '2026-07-01T09:00:00Z')]
    page_two = [ev('add', label, HUMAN_ID, '2026-08-06T10:00:00Z')]

    assert handover(GitlabPagesClient.new([page_one, page_two]))
      .moved_since?(FakeIssue.new([label]), 42, Time.utc(2026, 8, 1))
  end

  # --- a failure part-way through the walk -------------------------------

  # Page 1 read fine, page 2 did not. Answering from page 1 would be the very
  # defect this file is about, reached through an outage instead of a missing
  # call; `GitlabHelpers.answer` has to cover every page turn, not only the
  # first request.
  def test_a_transport_failure_on_a_later_page_aborts_the_read
    page_one = noise(PAGE)
    client = GitlabPagesClient.new([page_one, noise(3)], fail_on_page: 2,
                                                         error: Errno::ECONNRESET.new('Connection reset by peer'))

    assert_raises(ApiUnavailableError) do
      handover(client).todo_reapplied_after?(15_673, FINISHED_AT)
    end
  end

  # The same failure through `verdict`, the consumer that closes tickets.
  def test_a_transport_failure_on_a_later_page_aborts_a_verdict
    label = POWERPANNE['label_done']
    client = GitlabPagesClient.new([noise(PAGE), noise(3)], fail_on_page: 2,
                                                            error: Errno::ECONNRESET.new('Connection reset by peer'))

    assert_raises(ApiUnavailableError) { handover(client).verdict(FakeIssue.new([label]), 42) }
  end

  # And through the client production actually holds: pages 2..N reach
  # `GitlabRequestCounter#get` via `own_pages`, which records the transport
  # failure and re-raises — still inside `answer`, so still an abort.
  def test_a_later_page_failing_behind_the_request_counter_is_recorded_and_aborts
    raw = GitlabPagesClient.new([noise(PAGE), noise(3)], fail_on_page: 2,
                                                         error: Errno::ECONNRESET.new('Connection reset by peer'))

    assert_raises(ApiUnavailableError) do
      handover(GitlabRequestCounter.new(raw)).todo_reapplied_after?(15_673, FINISHED_AT)
    end
    assert_equal [%w[get Errno::ECONNRESET]], GitlabTransportFailure.pluck(:endpoint, :error_class)
  end

  # --- what the read costs, and under which name -------------------------

  # Autodev #116 chose the gem's named method plus `auto_paginate` over a raw
  # `get` with `per_page: 100`, and the reason is this assertion: the request
  # counter of Autodev #96 names a request after the method it forwards, so a
  # raw `get` would file the first page under `get` and the per-endpoint
  # breakdown would lose its `issue_label_events` line. The pages after the
  # first go through `own_pages` and are counted under `get` either way.
  def test_a_two_page_read_is_counted_as_two_requests_the_first_under_its_own_name
    client = GitlabRequestCounter.new(GitlabPagesClient.new([noise(PAGE), noise(15)]))

    handover(client).todo_reapplied_after?(15_673, FINISHED_AT)

    assert_equal({ 'issue_label_events' => 1, 'get' => 1 },
                 GitlabRequestStat.pluck(:endpoint, :count).to_h)
  end
end
