# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/activity_logger'

# Autodev #124: the activity note links the issue's page on the dashboard.
# The link lives in the header line — the one line every writer of the note
# keeps — and the header is rebuilt on every update, which is how notes
# written before the link existed receive it.
module DashboardLinkFixtures
  include DatabaseTestHelper

  Note = Struct.new(:id, :body)

  # Holds one note per id, the way GitLab does: what `edit_issue_note` writes
  # is what the next `issue_note` reads back.
  class NoteStore
    attr_reader :bodies

    def initialize
      @bodies = {}
      @next_id = 500
    end

    def create_issue_note(_project, _iid, body)
      id = (@next_id += 1)
      @bodies[id] = body
      Note.new(id, body)
    end

    def issue_note(_project, _iid, id) = Note.new(id, @bodies.fetch(id))

    def edit_issue_note(_project, _iid, id, body)
      @bodies[id] = body
      Note.new(id, body)
    end
  end

  BASE = 'https://autodev.netbird.modulotech.fr/'
  LEGACY_ENTRY = '- `09-22 16:56` — :rocket: Traitement demarre'
  LEGACY_HEADERS = {
    fr: ":robot: **autodev** (v1.0.0.alpha.54) — Journal d'activite",
    en: ':robot: **autodev** (v1.0.0.alpha.54) — Activity log'
  }.freeze

  def setup
    setup_database
    @saved_config = Web.config
    @client = NoteStore.new
    @ctx = ActivityLogger::Ctx.new(@client, 'g/p', nil)
  end

  def teardown
    Web.config = @saved_config
  end

  def with_dashboard(url)
    Web.config = { 'dashboard_url' => url }
  end

  def issue_url(issue) = "https://autodev.netbird.modulotech.fr/issues/#{issue.id}"

  def body_of(issue) = @client.bodies.fetch(issue.reload.activity_note_id)

  def lines_of(issue) = body_of(issue).split("\n")

  def header_of(issue) = lines_of(issue).first

  def expected_header(issue, locale: :fr)
    header = Locales.t(:activity_header, locale: locale, tag: ActivityLogger.tag)
    "#{header} · #{Locales.t(:activity_dashboard_link, locale: locale, url: issue_url(issue))}"
  end

  # An issue whose note already exists with `body`, as written by an earlier version.
  def issue_with_note(body, **attrs)
    issue = create_issue(**attrs)
    issue.update!(activity_note_id: @client.create_issue_note('g/p', issue.issue_iid, body).id)
    issue
  end

  def legacy_body(locale = :fr) = "#{LEGACY_HEADERS.fetch(locale)}\n\n#{LEGACY_ENTRY}"
end

# A note autodev creates.
class ActivityLoggerDashboardLinkTest < Minitest::Test
  include DashboardLinkFixtures

  def test_a_new_note_links_the_row_not_the_gitlab_iid
    with_dashboard(BASE)
    issue = create_issue(issue_iid: 9_999)

    ActivityLogger.post(@ctx, issue, :started)

    assert_equal expected_header(issue), header_of(issue)
    refute_includes body_of(issue), '/issues/9999'
    refute_includes body_of(issue), '//issues'
  end

  def test_the_link_is_on_the_header_line_and_the_layout_is_unchanged
    with_dashboard(BASE)
    issue = create_issue

    ActivityLogger.post(@ctx, issue, :started)
    lines = lines_of(issue)

    assert_equal [expected_header(issue), ''], lines.first(2)
    assert_match(/\A- `/, lines[2])
    assert_equal 1, body_of(issue).scan(issue_url(issue)).size
  end

  def test_without_a_dashboard_url_the_note_is_posted_without_a_link
    [nil, {}, { 'dashboard_url' => nil }].each do |config|
      Web.config = config
      issue = create_issue

      ActivityLogger.post(@ctx, issue, :started)

      refute_nil issue.reload.activity_note_id, config.inspect
      assert_equal Locales.t(:activity_header, locale: :fr, tag: ActivityLogger.tag), header_of(issue)
    end
  end

  def test_the_label_follows_the_issue_locale
    with_dashboard(BASE)
    fr = create_issue(locale: 'fr')
    en = create_issue(locale: 'en')

    ActivityLogger.post(@ctx, fr, :started)
    ActivityLogger.post(@ctx, en, :started)

    assert_equal expected_header(fr, locale: :fr), header_of(fr)
    assert_equal expected_header(en, locale: :en), header_of(en)
  end

  def test_the_label_is_a_markdown_link_that_says_a_sign_in_is_required
    fr = Locales.t(:activity_dashboard_link, locale: :fr, url: 'u')
    en = Locales.t(:activity_dashboard_link, locale: :en, url: 'u')

    assert_match(/\A\[[^\]]+\]\(u\) .*connexion Autodev requise/, fr)
    assert_match(/\A\[[^\]]+\]\(u\) .*sign-in required/, en)
  end

  def test_every_locales_header_starts_with_the_prefix_the_rewrite_guards_on
    assert_equal ':robot: **autodev**', ActivityLogger::HEADER_PREFIX
    %i[fr en].each do |locale|
      header = Locales.t(:activity_header, locale: locale, tag: ActivityLogger.tag)

      assert header.start_with?(ActivityLogger::HEADER_PREFIX), "#{locale}: #{header}"
    end
  end
end

# A note that already exists: every update rebuilds its header.
class ActivityLoggerDashboardLinkUpdateTest < Minitest::Test
  include DashboardLinkFixtures

  def test_a_note_written_before_the_link_receives_it_at_its_next_update
    with_dashboard(BASE)
    issue = issue_with_note(legacy_body)

    ActivityLogger.post(@ctx, issue, :cloning, detail: 'depth: 1')
    lines = lines_of(issue)

    assert_equal [expected_header(issue), '', LEGACY_ENTRY], lines.first(3)
    assert_includes lines[3], 'Clonage'
    assert_equal 4, lines.size
  end

  def test_a_note_that_holds_only_its_header_is_rebuilt
    with_dashboard(BASE)
    issue = issue_with_note(LEGACY_HEADERS[:fr])

    ActivityLogger.post(@ctx, issue, :started)

    assert_equal expected_header(issue), header_of(issue)
  end

  def test_an_english_note_is_rebuilt_in_english
    with_dashboard(BASE)
    issue = issue_with_note(legacy_body(:en), locale: 'en')

    ActivityLogger.post(@ctx, issue, :cloning, detail: 'depth: 1')

    assert_equal expected_header(issue, locale: :en), header_of(issue)
  end

  def test_a_replaced_line_keeps_the_link
    with_dashboard(BASE)
    issue = create_issue
    pattern = /— :mag:.*(?:pipeline|statut du pipeline)/

    3.times { ActivityLogger.post(@ctx, issue, :pipeline_checking, since: '1 min', replace_pattern: pattern) }

    assert_equal expected_header(issue), header_of(issue)
    assert_equal 3, lines_of(issue).size
  end

  def test_the_size_cap_keeps_the_link
    with_dashboard(BASE)
    filler = Array.new((ActivityLogger::MAX_NOTE_BYTES / 100) + 10) { |i| "- `01-01 00:00` — #{'x' * 80} #{i}" }
    issue = issue_with_note([LEGACY_HEADERS[:fr], '', *filler].join("\n"))

    ActivityLogger.post(@ctx, issue, :started)

    assert_operator body_of(issue).length, :<=, ActivityLogger::MAX_NOTE_BYTES
    assert_equal expected_header(issue), header_of(issue)
  end

  def test_a_first_line_that_is_not_autodevs_header_is_left_alone
    with_dashboard(BASE)
    ["Somebody else's text", ':robot: something else', ':robot: **other-bot** — log'].each do |first|
      issue = issue_with_note("#{first}\n\n#{LEGACY_ENTRY}")

      ActivityLogger.post(@ctx, issue, :started)

      assert_equal first, header_of(issue)
    end
  end

  def test_a_changed_or_removed_dashboard_url_replaces_the_link
    with_dashboard('https://old.example/')
    issue = create_issue
    ActivityLogger.post(@ctx, issue, :started)

    with_dashboard(BASE)
    ActivityLogger.post(@ctx, issue, :cloning, detail: 'x')

    assert_equal expected_header(issue), header_of(issue)

    with_dashboard(nil)
    ActivityLogger.post(@ctx, issue, :cloning, detail: 'y')

    refute_includes body_of(issue), '/issues/'
  end
end
