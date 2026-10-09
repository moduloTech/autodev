# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/review_contract'
require 'autodev/review_publisher'

# Autodev #121 — the review side of "a functional divergence becomes a question".
#
# The signal is a structured field of the contract the review skill writes
# (owner, Q4): `category: functional | code`. "Divergence fonctionnelle" used to
# exist only as free text in PowerPanne's skill output — the four threads of MR
# !11409 carried it in their title and autodev read none of it.
#
# The category has to survive into GitLab, because the review and the fix run in
# different jobs: `MrFixer` recognises the thread later by
# `ReviewPublisher::FUNCTIONAL_MARKER`. And a functional finding has to *be* a
# thread — a decision somebody must take is not prose in a summary comment, which
# `MrFixer` never reads and which holds no delivery.
class AFunctionalFindingIsAThreadTest < Minitest::Test
  class NullLogger
    %i[info warn error debug].each { |level| define_method(level) { |*| nil } }
  end

  FakeRefs = Struct.new(:base_sha, :start_sha, :head_sha)
  FakeMr = Struct.new(:diff_refs)
  FakeNote = Struct.new(:position, :body)
  FakeDiscussion = Struct.new(:notes)
  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  # Records every discussion it is asked for. `refuse_positioned:` answers a
  # positioned post with GitLab's 400 (a merge request in conflict, Autodev #95);
  # `refuse_all:` refuses the unpositioned fallback too.
  class StubClient
    attr_reader :discussions, :notes

    attr_writer :outage

    def initialize(refuse_positioned: false, refuse_all: false, drop_position: false)
      @drop_position = drop_position
      @refuse_positioned = refuse_positioned
      @refuse_all = refuse_all
      @discussions = []
      @notes = []
    end

    def merge_request(_path, _iid) = FakeMr.new(FakeRefs.new('b', 's', 'h'))

    def create_merge_request_discussion(_path, _iid, opts)
      raise Errno::ECONNREFUSED if @outage
      raise bad_request if @refuse_all || (@refuse_positioned && opts[:position])

      @discussions << opts
      FakeDiscussion.new([FakeNote.new(@drop_position ? nil : opts[:position], opts[:body])])
    end

    def create_merge_request_note(_path, _iid, body)
      @notes << body
      FakeNote.new(nil, body)
    end

    def merge_request_notes(_path, _iid, **_opts)
      Struct.new(:items) { def auto_paginate = items }.new([])
    end

    private

    def bad_request
      Gitlab::Error::BadRequest.new(
        FakeResponse.new('Note {:line_code=>["can\'t be blank"]}', 400,
                         FakeRequest.new('https://gitlab.example', '/api/v4/x'))
      )
    end
  end

  def contract(findings)
    ReviewContract.parse({ verdict: 'changes_requested', summary: 'S', findings: findings }.to_json)
  end

  def publish(client, findings)
    ReviewPublisher.new(client: client, project_path: 'g/p', logger: NullLogger.new, locale: :fr)
                   .publish(mr_iid: 1, contract: contract(findings))
  end

  FUNCTIONAL = { file: 'app/x.rb', line: 3, severity: 'warning', category: 'functional',
                 body: 'Cron mensuel livré, une UI de période était demandée' }.freeze

  # === The contract ===

  def test_a_finding_without_category_is_code
    c = contract([{ file: 'a.rb', line: 1, severity: 'error', body: 'B' }])

    refute ReviewContract.functional?(c.inline.first)
  end

  def test_a_functional_finding_is_recognised
    c = contract([FUNCTIONAL])

    assert ReviewContract.functional?(c.inline.first)
  end

  # Strict like `severity`: a typo here would turn a product question into a
  # code fix without a word.
  def test_an_unknown_category_raises
    assert_raises(ReviewContract::InvalidError) do
      contract([{ file: 'a.rb', line: 1, severity: 'error', category: 'product', body: 'B' }])
    end
  end

  # The widening of the rule: a decision with no line is still a thread.
  def test_a_blocking_functional_finding_without_a_line_is_a_thread
    c = contract([{ severity: 'error', category: 'functional', body: 'B' }])

    assert_equal 1, c.inline.size
    assert_empty c.summary_only
  end

  # ...but only a blocking one: an `info` remains advice, whatever its category.
  def test_a_functional_info_stays_in_the_summary
    c = contract([{ severity: 'info', category: 'functional', body: 'B' }])

    assert_empty c.inline
    assert_equal 1, c.summary_only.size
  end

  # And the widening is the functional category's alone (Autodev #74's rule is
  # unchanged for code).
  def test_a_blocking_code_finding_without_a_line_stays_in_the_summary
    c = contract([{ severity: 'error', category: 'code', body: 'B' }])

    assert_empty c.inline
  end

  # === The publication ===

  def test_a_functional_thread_carries_the_marker_and_the_label # rubocop:disable Minitest/MultipleAssertions
    client = StubClient.new
    publish(client, [FUNCTIONAL])

    body = client.discussions.first[:body]

    assert body.start_with?(ReviewPublisher::FUNCTIONAL_MARKER), 'the marker heads the thread'
    assert_includes body, Locales.t(:review_functional_finding_label, locale: :fr, tag: '**autodev**')
    assert_includes body, FUNCTIONAL[:body]
    assert client.discussions.first[:position], 'a located functional finding is still anchored'
  end

  def test_a_code_thread_carries_no_marker
    client = StubClient.new
    publish(client, [FUNCTIONAL.merge(category: 'code')])

    refute_includes client.discussions.first[:body], ReviewPublisher::FUNCTIONAL_MARKER
  end

  def test_a_functional_finding_without_a_location_is_an_unpositioned_thread # rubocop:disable Minitest/MultipleAssertions
    client = StubClient.new
    result = publish(client, [{ severity: 'error', category: 'functional', body: 'Décision' }])

    assert_equal 1, client.discussions.size
    assert_nil client.discussions.first[:position]
    assert_equal 1, result[:posted], 'an unpositioned thread holds the verdict like an anchored one'
    assert_equal 0, result[:demoted]
  end

  # Autodev #95 demotes a refused position into the summary comment. For a
  # functional finding that would lose the question: it falls back to a thread.
  def test_a_refused_functional_position_falls_back_to_an_unpositioned_thread # rubocop:disable Minitest/MultipleAssertions
    client = StubClient.new(refuse_positioned: true)
    result = publish(client, [FUNCTIONAL])

    assert_equal 1, client.discussions.size
    assert_nil client.discussions.first[:position]
    assert_includes client.discussions.first[:body], ReviewPublisher::FUNCTIONAL_MARKER
    assert_equal [1, 0], [result[:posted], result[:demoted]]
  end

  # GitLab's polite decline (Autodev #74): the positioned post is accepted and
  # comes back with a null position. That is already a thread carrying the
  # marker — posting the fallback on top would ask the same question twice.
  def test_a_politely_declined_functional_position_is_not_posted_twice
    client = StubClient.new(drop_position: true)
    result = publish(client, [FUNCTIONAL])

    assert_equal 1, client.discussions.size
    assert_equal [1, 0], [result[:posted], result[:demoted]]
  end

  # Code findings keep #95's behaviour exactly.
  def test_a_refused_code_position_is_still_demoted
    client = StubClient.new(refuse_positioned: true)
    result = publish(client, [FUNCTIONAL.merge(category: 'code')])

    assert_empty client.discussions
    assert_equal [0, 1], [result[:posted], result[:demoted]]
  end

  # Only GitLab's own refusal demotes; an outage aborts the publication, like
  # every other post of this class (Autodev #95).
  def test_an_outage_on_the_unpositioned_thread_aborts_the_publication
    client = StubClient.new
    client.outage = true

    assert_raises(ApiUnavailableError) { publish(client, [{ severity: 'error', category: 'functional', body: 'D' }]) }
    assert_empty client.notes, 'no summary posted over a review that did not go through'
  end

  def test_a_refused_fallback_is_demoted_into_the_summary
    client = StubClient.new(refuse_all: true)
    result = publish(client, [FUNCTIONAL])

    assert_equal [0, 1], [result[:posted], result[:demoted]]
    assert_includes client.notes.last, FUNCTIONAL[:body]
  end
end
