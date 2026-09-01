# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/review_contract'
require 'autodev/review_publisher'

# Autodev #95, second of three files — see
# `an_invalid_request_is_not_an_outage_test.rb` for the classification this
# builds on.
#
# `ReviewPublisher` already knew one way GitLab declines a position — it accepts
# the discussion and returns a note whose `position` is null — and demoted the
# finding into the summary comment. The 400 is the *other* way it declines, and it
# had no answer for it at all.
#
# The fallback belongs here rather than to the caller: this is the only object
# that knows what it was trying to post, and a review that produced its findings
# must not lose them because it cannot pin them to a line. The human reviewer
# reads them either way.
#
# Where the fallback stops is the *delivery*, and this file deliberately does not
# reach it. `publish` reports `posted` and `demoted` apart so the caller can weigh
# them against the contract's verdict; that a review with every finding demoted
# must not go out as reviewed is `a_demoted_review_is_not_a_delivery_test.rb`,
# added by this ticket's neutral review after the first round delivered one.
class TheReviewFallsBackToAnUnanchoredCommentTest < Minitest::Test
  class NullLogger
    %i[info warn error debug].each { |level| define_method(level) { |*| nil } }
  end

  FakeRefs = Struct.new(:base_sha, :start_sha, :head_sha)
  FakeMr = Struct.new(:diff_refs)
  FakeNote = Struct.new(:position)
  FakeNote2 = Struct.new(:body)
  FakeDiscussion = Struct.new(:notes)
  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  # The production body, verbatim in shape: a merge request in conflict has no
  # resolvable line codes, so every position it is handed is refused.
  def conflicted_mr_error
    Gitlab::Error::ResponseError.new(
      FakeResponse.new('400 Bad request - Note {:line_code=>["can\'t be blank", "must be a valid line code"]}',
                       400, FakeRequest.new('https://gitlab.example', '/api/v4/x'))
    )
  end

  def outage_error
    Gitlab::Error::ResponseError.new(
      FakeResponse.new('boom', 500, FakeRequest.new('https://gitlab.example', '/api/v4/x'))
    )
  end

  class StubClient
    attr_reader :discussions, :notes

    def initialize(raise_on_discussion: nil, raise_on_note: nil)
      @raise_on_discussion = raise_on_discussion
      @raise_on_note = raise_on_note
      @discussions = []
      @notes = []
    end

    def merge_request(_path, _iid) = FakeMr.new(FakeRefs.new('b', 's', 'h'))

    def create_merge_request_discussion(_path, _iid, opts)
      raise @raise_on_discussion if @raise_on_discussion

      @discussions << opts
      FakeDiscussion.new([FakeNote.new(opts[:position])])
    end

    def create_merge_request_note(_path, _iid, body)
      raise @raise_on_note if @raise_on_note

      @notes << body
      FakeNote.new(nil)
    end

    def merge_request_notes(_path, _iid, **_opts)
      stored = @notes.map { |b| FakeNote2.new(b) }
      Struct.new(:items) { def auto_paginate = items }.new(stored)
    end
  end

  def contract(findings)
    ReviewContract.parse({ verdict: 'changes_requested', summary: 'S', findings: findings }.to_json)
  end

  def publisher(client)
    ReviewPublisher.new(client: client, project_path: 'g/a', logger: NullLogger.new, locale: :fr)
  end

  def finding = [{ 'file' => 'a.rb', 'line' => 12, 'severity' => 'error', 'body' => 'the finding body' }]

  def test_a_refused_position_demotes_the_finding_into_the_summary_comment
    client = StubClient.new(raise_on_discussion: conflicted_mr_error)
    result = publisher(client).publish(mr_iid: 11_258, contract: contract(finding))

    assert_equal({ posted: 0, demoted: 1 }, result)
    assert_includes client.notes.first, 'the finding body'
  end

  # The review ran, judged and published: `publish` answers a Hash, never nil, so
  # nothing here reads as "this poll could not conclude".
  #
  # What that Hash means for the *delivery* is not decided here, and the first
  # round of this ticket let it be: `publish_from_contract` read any Hash as
  # `true`, `review_count` moved, and a `changes_requested` review with every
  # finding demoted was delivered under `label_done` two polls later. `posted` and
  # `demoted` are reported apart precisely so that decision can be taken with the
  # verdict — see `a_demoted_review_is_not_a_delivery_test.rb`.
  def test_the_review_still_counts_as_published
    client = StubClient.new(raise_on_discussion: conflicted_mr_error)

    refute_nil publisher(client).publish(mr_iid: 11_258, contract: contract(finding))
  end

  # The control that keeps the fallback from becoming the old defect in reverse: a
  # 500 while posting is an outage, nothing is demoted, and the poll aborts.
  def test_an_outage_while_posting_is_not_demoted
    client = StubClient.new(raise_on_discussion: outage_error)

    assert_raises(ApiUnavailableError) do
      publisher(client).publish(mr_iid: 11_258, contract: contract(finding))
    end
    assert_empty client.notes
  end

  # The fallback's own failure. Nothing further can be attempted for this review,
  # so the error keeps travelling — bounded one frame up.
  def test_a_refused_summary_comment_still_raises
    client = StubClient.new(raise_on_discussion: conflicted_mr_error, raise_on_note: conflicted_mr_error)

    assert_instance_of InvalidRequestError, assert_raises(InvalidRequestError) {
      publisher(client).publish(mr_iid: 11_258, contract: contract(finding))
    }
  end
end
