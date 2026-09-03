# frozen_string_literal: true

require 'delegate'

# Autodev #96: wraps the Gitlab::Client `GitlabHelpers.build_gitlab_client`
# returns so every call it forwards — read or write — is counted, without
# any of that method's twelve call sites changing. See the design spec
# (docs/superpowers/specs/2026-09-03-count-gitlab-requests-design.md) for
# why this sits at the client rather than inside `GitlabHelpers.answer`:
# `answer` only ever wraps reads, and eleven of the twelve write methods
# below are called directly.
#
# A plain top-level class, not `Autodev::GitlabRequestCounter` — it lives
# next to `GitlabHelpers`/`GitlabFailure` in `lib/autodev`, which is off the
# Zeitwerk autoload path by design (see lib/autodev.rb's header comment).
class GitlabRequestCounter < SimpleDelegator
  # The gem's own naming is not uniform enough for a prefix rule alone:
  # `job_play`/`job_retry` are writes with no prefix in common with
  # `create_`/`edit_`/`resolve_`. So: prefixes for the regular cases, a short
  # named exception list for the irregular ones. Checked against every
  # distinct `client.*` method this codebase calls today (see the spec) —
  # covers all twelve writes in use, defaults everything else to `:read`.
  WRITE_PREFIXES = %w[create_ edit_ update_ delete_ remove_ resolve_ upload_ retry_].freeze
  WRITE_METHODS = %w[job_play job_retry].freeze

  class << self
    def classify(name)
      name = name.to_s
      return :write if WRITE_METHODS.include?(name)
      return :write if WRITE_PREFIXES.any? { |prefix| name.start_with?(prefix) }

      :read
    end
  end

  # The gem's own configuration accessors (`endpoint`, `private_token`, …)
  # issue no request, and `PaginatedResponse#client_relative_path` reads
  # `@client.endpoint` on **every** page turn — so once the proxy owns the
  # response (see `own_pages`), counting every message turned the fix for
  # under-counting into over-counting: two stats per page for one HTTP
  # request, plus a bogus `endpoint` row in the per-endpoint breakdown
  # (second neutral review, N3). Derived from the gem rather than listed, so
  # a new option cannot reopen it.
  NON_REQUEST_METHODS = (
    ::Gitlab::Configuration::VALID_OPTIONS_KEYS.flat_map { |key| [key.to_s, "#{key}="] } +
    %w[reset options]
  ).to_set.freeze

  def method_missing(name, ...)
    return super unless __getobj__.respond_to?(name)
    return __getobj__.public_send(name, ...) if NON_REQUEST_METHODS.include?(name.to_s)

    kind = self.class.classify(name)
    ::GitlabRequestStat.record!(kind: kind, endpoint: name.to_s)
    own_pages(call_and_track_failures(name, kind, ...))
  end

  def respond_to_missing?(name, include_private = false)
    __getobj__.respond_to?(name, include_private) || super
  end

  private

  # The pages after the first, which were escaping the count (alpha-53 review,
  # G4). The gem builds its `Gitlab::PaginatedResponse` with `parsed.client =
  # self` — `self` being the **raw** client, not this proxy — so
  # `.auto_paginate` and `.each_page` fetched pages 2..N through
  # `Gitlab::Client#get` directly: uncounted, and unlogged when they failed by
  # transport. Eight call sites paginate in `lib/`, one of them
  # (`GitlabMembershipSync`'s `all_members`) without a `per_page`, so it
  # paginates from the 21st member on.
  #
  # Reassigning the response's client to the proxy puts those requests back
  # through `method_missing`, where `get` is classified `:read` and counted
  # like everything else. Guarded on `respond_to?` because most return values
  # are plain objects with no client to reassign.
  def own_pages(result)
    result.client = self if result.respond_to?(:client=)
    result
  rescue StandardError
    result # a return value that refuses the reassignment is still the answer
  end

  def call_and_track_failures(name, kind, ...)
    __getobj__.public_send(name, ...)
  rescue *::GitlabHelpers::TRANSPORT_ERRORS => e
    ::GitlabTransportFailure.record!(kind: kind, endpoint: name.to_s, error: e,
                                     caller_location: caller_locations(2, 1)&.first&.to_s)
    raise
  end
end
