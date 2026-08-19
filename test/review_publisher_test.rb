# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/review_contract'
require 'autodev/review_publisher'

# `NullLogger` and `gitlab_response_error` are not shared helpers (Autodev #74,
# task 3 brief): kept local rather than added to `test/test_helper.rb`, per the
# task's own resolution, so this file and a later task's do not race on a
# shared file. `test/api_failure_is_not_a_verdict_test.rb` carries the model —
# its inline `api_error` builder — for the same minimum surface
# `Gitlab::Error::ResponseError` needs to construct.

# A logger that discards everything, for a class that only needs one.
class NullLogger
  %i[info warn error debug].each { |level| define_method(level) { |*| nil } }
end

# Autodev posts the review itself, with its own PAT (Autodev #74) — the skill
# stops before writing, which is its own invariant.
class ReviewPublisherTest < Minitest::Test
  FakeRefs = Struct.new(:base_sha, :start_sha, :head_sha)
  FakeMr = Struct.new(:diff_refs)
  FakeNote = Struct.new(:position)
  FakeNote2 = Struct.new(:body)
  FakeDiscussion = Struct.new(:notes)

  # Gitlab::Error::ResponseError builds its message from the real HTTP
  # response; this is the minimum surface it reads (mirrors
  # test/api_failure_is_not_a_verdict_test.rb's `api_error`).
  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  def gitlab_response_error
    Gitlab::Error::ResponseError.new(
      FakeResponse.new('boom', 500, FakeRequest.new('https://gitlab.example', '/api/v4/x'))
    )
  end

  class StubClient
    attr_reader :discussions, :notes

    def initialize(refs: FakeRefs.new('b', 's', 'h'), anchor: true, raise_on_post: nil)
      @refs = refs
      @anchor = anchor
      @raise_on_post = raise_on_post
      @discussions = []
      @notes = []
    end

    def merge_request(_path, _iid) = FakeMr.new(@refs)

    def create_merge_request_discussion(_path, _iid, opts)
      raise @raise_on_post if @raise_on_post

      @discussions << opts
      FakeDiscussion.new([FakeNote.new(@anchor ? opts[:position] : nil)])
    end

    def create_merge_request_note(_path, _iid, body)
      @notes << body
      FakeNote.new(nil)
    end

    # `already_published?` reads this back; `auto_paginate` mirrors the gem's
    # paginated response.
    def merge_request_notes(_path, _iid, **_opts)
      stored = @notes.map { |b| FakeNote2.new(b) }
      Struct.new(:items) { def auto_paginate = items }.new(stored)
    end
  end

  def contract(findings, summary: 'S')
    ReviewContract.parse({ verdict: 'changes_requested', summary: summary, findings: findings }.to_json)
  end

  def publisher(client)
    ReviewPublisher.new(client: client, project_path: 'g/a', logger: NullLogger.new, locale: :fr)
  end

  def test_an_inline_finding_is_posted_as_a_positioned_discussion
    client = StubClient.new
    result = publisher(client).publish(mr_iid: 7, contract: contract(
      [{ 'file' => 'a.rb', 'line' => 12, 'severity' => 'error', 'body' => 'boom' }]
    ))

    assert_equal 1, result[:posted]
    position = client.discussions.first[:position]

    assert_equal ['a.rb', 12, 'h'], position.values_at(:new_path, :new_line, :head_sha)
  end

  def test_the_summary_comment_is_posted_last
    client = StubClient.new
    publisher(client).publish(mr_iid: 7, contract: contract(
      [{ 'file' => 'a.rb', 'line' => 1, 'severity' => 'error', 'body' => 'b' }]
    ))

    assert_equal 1, client.notes.size
    assert_equal 1, client.discussions.size
  end

  def test_a_finding_that_will_not_anchor_is_demoted_not_lost
    client = StubClient.new(anchor: false)
    result = publisher(client).publish(mr_iid: 7, contract: contract(
      [{ 'file' => 'a.rb', 'line' => 1, 'severity' => 'error', 'body' => 'unanchorable' }]
    ))

    assert_equal 1, result[:demoted]
    assert_includes client.notes.first, 'unanchorable'
  end

  def test_absent_diff_refs_post_nothing_and_are_not_a_verdict
    client = StubClient.new(refs: nil)

    assert_nil publisher(client).publish(mr_iid: 7, contract: contract([]))
    assert_empty client.discussions
    assert_empty client.notes
  end

  def test_a_second_pass_does_not_post_twice
    client = StubClient.new
    published = publisher(client)
    published.publish(mr_iid: 7, contract: contract(
      [{ 'file' => 'a.rb', 'line' => 1, 'severity' => 'error', 'body' => 'b' }]
    ))
    published.publish(mr_iid: 7, contract: contract(
      [{ 'file' => 'a.rb', 'line' => 1, 'severity' => 'error', 'body' => 'b' }]
    ))

    assert_equal 1, client.discussions.size
    assert_equal 1, client.notes.size
  end

  def test_a_gitlab_error_while_posting_raises_api_unavailable
    client = StubClient.new(raise_on_post: gitlab_response_error)
    assert_raises(ApiUnavailableError) do
      publisher(client).publish(mr_iid: 7, contract: contract(
        [{ 'file' => 'a.rb', 'line' => 1, 'severity' => 'error', 'body' => 'b' }]
      ))
    end
  end
end
