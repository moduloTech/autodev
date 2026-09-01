# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_failure'

# Autodev #95 — a request GitLab refuses is not a request GitLab could not answer.
#
# `GitlabHelpers.answer` converted **every** `Gitlab::Error::ResponseError` into
# `ApiUnavailableError`, which is the right reading of a 500 or a timeout and the
# wrong reading of a 400: GitLab answered, promptly and precisely, that the
# request cannot succeed as it is formed. Waiting changes nothing, so the row came
# back to the watch having spent no counter, and the next cycle did it again.
#
# Measured in production on 01/09/2026, request powerpanne 15205, five times in
# eighty-seven minutes:
#
#     Pipeline check for MR !11258 could not conclude: GitLab did not answer the
#     mr_discussion read: Server responded with code 400, message: 400 Bad request
#     - Note {:line_code=>["can't be blank", "must be a valid line code"]}.
#
# The merge request was in conflict, so its diff had no resolvable line codes; the
# skill review ran correctly for eighteen minutes, produced its findings, and
# `ReviewPublisher` then tried to anchor them. Each poll paid for the whole review
# again — close to 90% of a worker thread, continuously, until the line was cut by
# hand.
#
# ## The three files of this ticket
#
# This one pins the classification at the conversion point;
# `a_refused_position_falls_back_to_a_comment_test.rb` pins what `ReviewPublisher`
# does with a refusal; `a_refused_request_is_bounded_and_signalled_test.rb` pins
# what the two boundaries do when even the fallback is refused. One top-level
# class each, which is also what keeps `Style/OneClassPerFile` quiet.
#
# ## What this file pins, and the one thing it deliberately does not
#
# The ticket's plan asked that a refused publication "not produce an
# `ApiUnavailableError`". It produces `InvalidRequestError`, which **is** a member
# of that family — the same shape `MissingTargetBranchError` took in Autodev #91,
# and for the same reason: every boundary in this codebase already knows how to
# end a unit of work that concluded nothing, and a sibling class would instead
# reach `PipelineMonitor#check`'s generic `rescue StandardError` and, in
# `MrFixer#fix`, no rescue at all — ActiveJob, Solid Queue's failed executions, a
# human needed for something no cycle retries. Answering one question twice is
# what this repository keeps paying for.
#
# What the family carried and had to be taken away is the *waiting*, exactly as in
# #91. So the assertions below are the substance of the plan rather than its
# letter: the error is not the plain `ApiUnavailableError` any more, its message
# does not accuse GitLab of going dark, the findings are published anyway, and the
# line does not come back for ever.
class AnInvalidRequestIsNotAnOutageTest < Minitest::Test
  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  # The gem picks the class from the status in `Gitlab::Request`, not in the
  # constructor, so a fixture that calls `ResponseError.new` directly builds the
  # wrong class for every mapped code — which matters here, since `NotFound` is
  # the one `ReviewSkillSource#confirm_ref!` reads back off `Ruby`'s `cause`.
  def response_error(code, message = 'boom')
    response = FakeResponse.new(message, code, FakeRequest.new('https://gitlab.example', '/api/v4/x'))
    (Gitlab::Error::STATUS_MAPPINGS[code] || Gitlab::Error::ResponseError).new(response)
  end

  def raised(error)
    GitlabHelpers.answer(:mr_discussion) { raise error }
  rescue StandardError => e
    e
  end

  # --- 1. the defect ---------------------------------------------------------

  # The production case. `assert_instance_of`, not `assert_kind_of`: the whole
  # point is that this is no longer the class that means "GitLab went dark".
  def test_a_400_is_a_refusal_not_an_outage
    assert_instance_of InvalidRequestError, raised(response_error(400))
  end

  # A visible chain does not lie (Autodev #63, #81, #85). The line an operator
  # read for five polls said GitLab had not answered, while GitLab had.
  def test_the_message_does_not_claim_gitlab_went_dark
    message = raised(response_error(400)).message

    refute_includes message, 'did not answer'
    assert_includes message, '400'
  end

  # 422 is the same event under another number — GitLab understood the request and
  # refused its content. Nothing on this path distinguishes them.
  def test_a_422_is_a_refusal_too
    assert_instance_of InvalidRequestError, raised(response_error(422))
  end

  def test_a_refusal_carries_the_endpoint_and_the_status
    error = raised(response_error(400))

    assert_equal [:mr_discussion, 400], [error.what, error.status]
  end

  # --- 2. the controls: an outage stays an outage ---------------------------

  # "Do not make a 5xx less protected" is the invariant of Autodev #62, #67 and
  # #73, and this ticket narrows the family rather than weakening it.
  def test_a_500_is_still_an_outage
    assert_instance_of ApiUnavailableError, raised(response_error(500))
  end

  def test_a_503_is_still_an_outage
    assert_instance_of ApiUnavailableError, raised(response_error(503))
  end

  # The alpha-50 half of this subject (Autodev #62, third round): transport
  # failures are outages, and they are not `ResponseError`s at all.
  def test_a_timeout_is_still_an_outage
    assert_instance_of ApiUnavailableError, raised(Net::ReadTimeout.new)
  end

  def test_a_reset_connection_is_still_an_outage
    assert_instance_of ApiUnavailableError, raised(Errno::ECONNRESET.new)
  end

  # 429 is a rate limit: the request is perfectly well formed and the answer is to
  # come back later, which is precisely what the outage reading does.
  def test_a_rate_limit_is_still_an_outage
    assert_instance_of ApiUnavailableError, raised(response_error(429))
  end

  # 401/403 mean autodev's credential is dead or refused. That is systemic, it is
  # not a property of this request, and `MrReviewTokenProbe` + the health card are
  # what surface it — giving a request up on it would hand the wrong operator the
  # wrong ticket.
  def test_a_dead_credential_is_still_an_outage
    assert_instance_of ApiUnavailableError, raised(response_error(401))
    assert_instance_of ApiUnavailableError, raised(response_error(403))
  end

  # 404 has to stay in the family, and not only because several callers read it as
  # a full answer *inside* the block (`ReviewSkillSource#file_on_ref?`,
  # `TargetBranch#of_merge_request`, `IssueProcessor#branch_exists_on_remote?`).
  # `ReviewSkillSource#confirm_ref!` reads it back off the converted exception —
  # `raise unless e.cause.is_a?(NotFound)` — so reclassifying it here would break
  # the one place that turns a 404 into `target_branch_missing`.
  def test_a_404_stays_in_the_outage_family_because_confirm_ref_reads_it_back
    error = raised(response_error(404))

    assert_instance_of ApiUnavailableError, error
    assert_instance_of Gitlab::Error::NotFound, error.cause
  end

  # Unchanged from the alpha-50 round: reading a bug in this repository as "GitLab
  # is down" is the same lie reversed, and reading it as "the request is invalid"
  # would be a third one.
  def test_a_programming_error_still_travels_as_itself
    assert_raises(NoMethodError) { GitlabHelpers.answer(:x) { raise NoMethodError, 'nope' } }
  end
end
