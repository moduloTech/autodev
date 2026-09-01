# frozen_string_literal: true

# How a GitLab call that did not produce a value is *read* (Autodev #95).
#
# `GitlabHelpers.answer` is where a failed call stops being data; this is where it
# is decided which of the two failures it was. The pair is deliberate: `answer`
# owns the rule ("a failed read has no representation as data"), this owns the
# reading, and neither is expressed twice.
#
# Autodev #62's third round widened the family in one direction — every way a call
# fails to *complete* is the same event as a 500, so `SystemCallError`,
# `Timeout::Error`, `SocketError`, `OpenSSL::SSL::SSLError` and `EOFError` joined
# `Gitlab::Error::ResponseError`. This narrows the one member that can also mean
# something else entirely: a 4xx where GitLab parsed the request and refused it.
# Same subject, opposite direction, and the two only make sense together.
module GitlabFailure
  # The statuses on which GitLab did answer, and the answer is that the request
  # cannot succeed as it is formed.
  #
  # Read by status rather than by class on purpose: `Gitlab::Error::STATUS_MAPPINGS`
  # names thirteen codes and every other 4xx arrives as a bare `ResponseError`, so
  # a class-based list would silently classify by which codes the gem happened to
  # name.
  #
  # Two entries, and the shortness is the point — each code left out is left out
  # for a reason a reader can check:
  #
  #   * **400** and **422** are the same event under two numbers: GitLab parsed
  #     the request and refused its content. 400 is what a merge request in
  #     conflict answers to a positioned discussion, which is the case this
  #     ticket is about.
  #   * **404** stays an outage, and not only because three callers read it as a
  #     full answer *inside* the block (`ReviewSkillSource#file_on_ref?`,
  #     `TargetBranch.of_merge_request`, `GitOperations#branch_exists_on_remote?`,
  #     none of which therefore reach this module).
  #     `ReviewSkillSource#confirm_ref!` reads it back **off the converted
  #     exception** — `raise unless e.cause.is_a?(NotFound)` — so moving it here
  #     would break the one place that turns a 404 into `target_branch_missing`.
  #   * **401** and **403** mean autodev's credential is dead or refused. That is
  #     systemic rather than a property of this request, retrying is the right
  #     answer while a human rotates a token, and `MrReviewTokenProbe` plus the
  #     health card are what surface it. Giving one request up on it would hand
  #     the wrong ticket to the wrong person.
  #   * **429** is a rate limit: the request is well formed and the answer is to
  #     come back later, which is exactly what the outage reading does.
  #   * **409**, **405**, **406** and the rest stay in the outage family
  #     deliberately, as the conservative default. Nothing in this codebase
  #     reaches a decision on them today, and the failure direction of this list
  #     is that a code wrongly called "invalid" can end a request.
  INVALID_REQUEST_STATUSES = [400, 422].freeze

  module_function

  # The exception `answer` will raise. Both are members of the
  # `ApiUnavailableError` family, so every boundary keeps behaving as it did; what
  # the refusal adds is a message that does not blame an outage and a signature
  # `InvalidRequestBound` can count.
  def classify(what, error)
    status = refusal_status(error)
    return InvalidRequestError.new(what, error, status) if status

    ApiUnavailableError.new(what, error)
  end

  # The status, or nil when this failure is not GitLab refusing the request.
  def refusal_status(error)
    return nil unless error.is_a?(Gitlab::Error::ResponseError)

    status = response_status(error)
    INVALID_REQUEST_STATUSES.include?(status) ? status : nil
  end

  # The HTTP status of a response error, or nil when it cannot be read. Shared
  # with `Autodev::MrReviewTokenProbe`, which asks the same question of the same
  # exception against its own list (401/403, the credential's own verdict) — one
  # definition, per the ruling of Autodev #72, #81 and #91.
  #
  # Coerced rather than trusted: `response_status` hands back whatever the HTTP
  # library put there, and a String would silently miss every `include?` above.
  # `exception: false` rather than a rescue — there is nothing here to swallow, and
  # the modifier-shaped alternatives are the form Autodev #67 spent a ticket on.
  def response_status(error)
    return nil unless error.respond_to?(:response_status)

    Integer(error.response_status, exception: false)
  end
end
