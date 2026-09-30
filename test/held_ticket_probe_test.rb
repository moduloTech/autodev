# frozen_string_literal: true

require_relative 'rails_helper'
require_relative 'database_test_helper'
require_relative 'gitlab_pages'

# A row autodev no longer follows (`done`, `closed`) whose GitLab ticket is
# still assigned to the bot is on nobody's list (Autodev #126): on 28/09/2026,
# 8 such rows on powerpanne/core. `HeldTicketProbe` reads the bot's own open
# tickets from the poll cycle, at most every `INTERVAL`, and records the
# terminal rows it finds there; `HealthReport#check_held_tickets` reads the
# record, passively like every other card.
#
# A project GitLab did not answer about is `unknown`, never "none held": a read
# that failed is not good news (Autodev #62).
# rubocop:disable Metrics/ClassLength -- one file per behaviour, and this one has
# three axes that only read together: what the probe asks GitLab and when, which
# rows the answer names, and the card that reads the record.
class HeldTicketProbeTest < ActiveSupport::TestCase
  include DatabaseTestHelper

  BOT_ID = 7

  # Answers `issues` per project and records every call. A project listed in
  # `raising` raises that error instead; a call that does not ask for the bot's
  # open tickets answers nothing, so a probe asking the wrong question finds no
  # held ticket at all.
  class FakeClient
    User = Struct.new(:id)

    attr_reader :calls

    def initialize(tickets: {}, raising: {})
      @tickets = tickets
      @raising = raising
      @calls = []
    end

    def user = User.new(BOT_ID)

    def issues(path, options = {})
      @calls << [path, options]
      raise @raising[path] if @raising.key?(path)

      asked_for_the_bot = options[:state] == 'opened' && options[:assignee_id] == BOT_ID
      Gitlab::PaginatedResponse.new(asked_for_the_bot ? Array(@tickets[path]) : [])
    end
  end

  class NullLogger
    def info(*, **) = nil
    def warn(*, **) = nil
    def error(*, **) = nil
    def debug(*, **) = nil
  end

  A = { 'path' => 'group/a' }.freeze
  B = { 'path' => 'group/b' }.freeze

  def setup
    setup_database
    GitlabHelpers.instance_variable_set(:@current_user_id, nil)
  end

  def teardown
    GitlabHelpers.instance_variable_set(:@current_user_id, nil)
  end

  def ticket(iid, id: iid + 50_000) = Gitlab::ObjectifiedHash.new('id' => id, 'iid' => iid)

  def row(path, iid, status) = create_issue(project_path: path, issue_iid: iid, status: status)

  def probe(client, projects: [A], now: Time.current)
    Autodev::HeldTicketProbe.probe!(config: {}, projects: projects, client: client,
                                    logger: NullLogger.new, now: now)
  end

  def held_pairs(state = Autodev::HeldTicketProbe.state)
    state[:held].map { |entry| [entry['path'], entry['iid']] }
  end

  def probe_event(age, held: [], checked: 1, unknown: 0)
    ActivityEvent.create!(issue_id: nil, kind: Autodev::HeldTicketProbe::KIND, level: 'info',
                          payload_json: JSON.generate(held: held, checked: checked, unknown: unknown),
                          created_at: Time.current - age)
  end

  # The card re-reads each named row's status (Autodev #126, adversarial
  # review), so the rows it names exist.
  def held_entries(count)
    Array.new(count) do |i|
      Issue.create!(id: 40 + i, project_path: 'group/a', issue_iid: 100 + i, status: 'done')
      { 'id' => 40 + i, 'path' => 'group/a', 'iid' => 100 + i, 'status' => 'done' }
    end
  end

  # The whole report, with the checks this test environment cannot satisfy
  # (no Solid Queue tables, an unmigrated queue database) stubbed healthy.
  def full_report
    healthy = { status: :ok, detail: 'stubbed', meta: {} }
    rep = Autodev::HealthReport.new(config: {}, poller_expected: false)
    rep.stub(:check_workers, healthy) do
      rep.stub(:check_queue, healthy) do
        rep.stub(:check_database, healthy) do
          rep.stub(:check_migrations, healthy) { rep.call }
        end
      end
    end
  end

  def card
    Autodev::HealthReport.new(config: {}).check(:held_tickets)[:checks][:held_tickets]
  end

  # --- what it asks GitLab ------------------------------------------------

  def test_it_asks_for_the_bots_open_tickets_and_names_the_terminal_row_among_them
    issue = row('group/a', 100, 'done')
    client = FakeClient.new(tickets: { 'group/a' => [ticket(100)] })
    probe(client)

    assert_equal [['group/a', { state: 'opened', assignee_id: BOT_ID, per_page: 100 }]], client.calls
    assert_equal [{ 'id' => issue.id, 'path' => 'group/a', 'iid' => 100, 'status' => 'done' }],
                 Autodev::HeldTicketProbe.state[:held]
  end

  # The bot's list is paginated like every GitLab list (Autodev #116): a held
  # ticket on page 2 is held all the same. `GitlabPagesClient` is a real
  # `Gitlab::Client`, so the walk is the gem's own `auto_paginate`.
  def test_a_held_ticket_on_the_second_page_is_found
    GitlabHelpers.instance_variable_set(:@current_user_id, BOT_ID)
    row('group/a', 321, 'closed')
    client = GitlabPagesClient.new([Array.new(20) { |i| { 'id' => i, 'iid' => 1000 + i } },
                                    [{ 'id' => 99, 'iid' => 321 }]])
    probe(client)

    assert_equal [1, 2], client.fetched
    assert_equal [['group/a', 321]], held_pairs
  end

  # --- which rows it names --------------------------------------------------

  def test_the_join_is_on_the_project_and_the_iid_not_the_iid_alone
    row('group/a', 100, 'done')
    row('group/b', 100, 'checking_pipeline')
    client = FakeClient.new(tickets: { 'group/a' => [ticket(100)], 'group/b' => [ticket(100)] })
    probe(client, projects: [A, B])

    assert_equal [['group/a', 100]], held_pairs
  end

  def test_only_done_and_closed_rows_are_held_ones
    %w[error pending needs_clarification checking_pipeline].each_with_index do |status, index|
      row('group/a', 200 + index, status)
    end
    row('group/a', 300, 'closed')
    client = FakeClient.new(tickets: { 'group/a' => [200, 201, 202, 203, 300].map { |iid| ticket(iid) } })
    probe(client)

    assert_equal [['group/a', 300]], held_pairs
  end

  # GitLab's `id` is global and `iid` is per project; the row stores the iid.
  def test_the_ticket_is_matched_on_its_iid_not_its_global_id
    row('group/a', 100, 'done')
    row('group/a', 9001, 'done')
    probe(FakeClient.new(tickets: { 'group/a' => [ticket(100, id: 9001)] }))

    assert_equal [['group/a', 100]], held_pairs
  end

  # --- a read that fails ------------------------------------------------------

  def test_a_project_gitlab_did_not_answer_about_is_unknown_and_the_other_still_counts
    row('group/a', 100, 'done')
    row('group/b', 100, 'done')
    client = FakeClient.new(tickets: { 'group/a' => [ticket(100)], 'group/b' => [ticket(100)] },
                            raising: { 'group/b' => Net::ReadTimeout.new })
    probe(client, projects: [A, B])
    state = Autodev::HeldTicketProbe.state

    assert_equal [2, 1], [state[:checked], state[:unknown]]
    assert_equal [['group/a', 100]], held_pairs(state)
  end

  def test_every_project_unreadable_is_said_on_the_card_never_read_as_none_held
    client = FakeClient.new(raising: { 'group/a' => Net::ReadTimeout.new, 'group/b' => Errno::ECONNRESET.new })
    probe(client, projects: [A, B])
    result = card

    assert_equal :ok, result[:status]
    assert_match(/2 project\(s\) could not be read/, result[:detail])
    refute_match(/\b0\b|no finished request/, result[:detail])
  end

  # --- what it records ------------------------------------------------------

  def test_nothing_held_is_still_recorded_as_one_machinery_event
    probe(FakeClient.new(tickets: { 'group/a' => [] }))
    events = ActivityEvent.where(kind: Autodev::HeldTicketProbe::KIND)

    assert_equal 1, events.count
    assert_empty events.first.payload['held']
  end

  # Written on a clock and read only as the newest row: machinery, so off the
  # timeline and inside the janitor's window.
  def test_the_record_is_a_machinery_kind_nobody_sees
    probe(FakeClient.new(tickets: { 'group/a' => [] }))

    assert_includes ActivityEvent::MACHINERY_KINDS, Autodev::HeldTicketProbe::KIND
    assert_empty ActivityEvent.user_visible.where(kind: Autodev::HeldTicketProbe::KIND)
  end

  # --- when it asks ---------------------------------------------------------

  def test_a_probe_younger_than_the_interval_asks_nothing
    probe_event(14.minutes)
    client = FakeClient.new

    assert_nil probe(client, projects: [A, B])
    assert_empty client.calls
  end

  # The boundary itself: a probe exactly `INTERVAL` old is due, one second
  # younger is not (the sabotage pass found `>=` → `>` survived 14 and 16 min).
  def test_the_interval_is_a_closed_bound
    now = Time.current
    { Autodev::HeldTicketProbe::INTERVAL => 2, Autodev::HeldTicketProbe::INTERVAL - 1.second => 0 }.each do |age, calls|
      ActivityEvent.where(kind: Autodev::HeldTicketProbe::KIND).delete_all
      ActivityEvent.create!(issue_id: nil, kind: Autodev::HeldTicketProbe::KIND, level: 'info',
                            payload_json: JSON.generate(held: [], checked: 2, unknown: 0), created_at: now - age)
      client = FakeClient.new
      Autodev::HeldTicketProbe.probe!(config: {}, projects: [A, B], client: client, now: now)

      assert_equal calls, client.calls.size, "age #{age.inspect}"
    end
  end

  def test_a_probe_older_than_the_interval_asks_once_per_project
    probe_event(16.minutes)
    client = FakeClient.new
    probe(client, projects: [A, B])

    assert_equal %w[group/a group/b], client.calls.map(&:first)
  end

  # The newest probe decides, whatever order the rows were written in.
  def test_the_newest_probe_decides_in_either_insertion_order
    [[2.hours, 5.minutes], [5.minutes, 2.hours]].each do |ages|
      ActivityEvent.where(kind: Autodev::HeldTicketProbe::KIND).delete_all
      ages.each { |age| probe_event(age) }
      client = FakeClient.new
      probe(client)

      assert_empty client.calls, "ages inserted as #{ages.inspect}"
    end
  end

  # --- the card -------------------------------------------------------------

  def test_the_card_is_ok_with_no_probe_on_file
    assert_equal [:ok, 'no held-ticket probe on file'], card.values_at(:status, :detail)
  end

  def test_the_card_ignores_a_probe_older_than_its_ttl
    probe_event(46.minutes, held: [{ 'id' => 1, 'path' => 'group/a', 'iid' => 1, 'status' => 'done' }])

    assert_equal [:ok, 'no held-ticket probe on file'], card.values_at(:status, :detail)
  end

  def test_the_card_warns_and_names_five_of_six_held_rows
    probe_event(1.minute, held: held_entries(6))
    result = card
    expected = (0..4).map { |i| "A##{40 + i}(group/a##{100 + i},done)" }.join(' ')

    assert_equal :warn, result[:status]
    assert_match(/\A6 /, result[:detail])
    assert_equal expected, result[:meta][:sample]
  end

  # A row that re-entered since the probe (todo reposed, bot reassigned) must
  # not be offered for Clore: that would cancel a live request.
  def test_a_row_that_has_since_re_entered_drops_out_of_the_card
    probe_event(1.minute, held: held_entries(1))
    Issue.find(40).update_columns(status: 'checking_pipeline')

    assert_equal :ok, card[:status]
  end

  def test_the_card_shows_the_status_the_row_holds_now
    probe_event(1.minute, held: held_entries(1))
    Issue.find(40).update_columns(status: 'closed')

    assert_equal 'A#40(group/a#100,closed)', card[:meta][:sample]
  end

  # With a project unread, the count is a floor and the detail says so.
  def test_a_warn_names_the_projects_it_could_not_read
    probe_event(1.minute, held: held_entries(1), checked: 2, unknown: 1)

    assert_match(/at least: 1 project\(s\) could not be read/, card[:detail])
  end

  def test_the_card_names_the_unreadable_project_when_nothing_is_held
    probe_event(1.minute, checked: 2, unknown: 1)
    result = card

    assert_equal :ok, result[:status]
    assert_match(/1 project\(s\) could not be read/, result[:detail])
  end

  # A held ticket is somebody's forgotten ticket, not an outage: `/healthz`
  # keeps answering 200.
  def test_a_warn_does_not_take_the_report_down
    probe_event(1.minute, held: held_entries(1))
    result = full_report

    assert_equal :warn, result[:checks][:held_tickets][:status]
    refute_equal :down, result[:status]
  end
end
# rubocop:enable Metrics/ClassLength
