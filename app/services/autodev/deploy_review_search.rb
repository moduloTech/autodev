# frozen_string_literal: true

module Autodev
  # Finds the merge request to deploy from what the person actually has in hand
  # (Autodev #45).
  #
  # `/deploy_review` speaks merge requests; a CSM looking at a "Ready for QA"
  # board speaks *tickets*. With 129 open MRs on powerpanne/core — 118 of them
  # already tracked by autodev — an unsearchable list was unusable, and the
  # single-page fetch left the 29 oldest unreachable outright. Both are handled
  # here.
  #
  # A query resolves two ways, unioned:
  #
  #   1. **Text** over title / source branch / iid. Cheap, and it covers the
  #      common case on its own because branches are named `<ticket-iid>-<slug>`.
  #   2. **GitLab's related merge requests**, when the query is a bare number.
  #      The convention is only a convention: ticket #16294's own MR was merged
  #      and the open MR carrying its work is named after another ticket, so
  #      nothing but GitLab knows the link. Related MRs are intersected with the
  #      open-MR list, which both filters out closed/merged ones and reuses the
  #      objects the view already renders.
  #
  # The related lookup is an enhancement, never a dependency: if it fails, the
  # text matches still come back. A failing *list* is different — that is the
  # whole answer, so it surfaces as `error` rather than an empty list that would
  # read as "nothing to deploy".
  class DeployReviewSearch
    Result = Struct.new(:merge_requests, :error)

    NUMERIC_QUERY = /\A#?(\d+)\z/

    def initialize(client:, project_path:, query: nil, logger: nil)
      @client = client
      @project_path = project_path
      @query = query.to_s.strip
      @logger = logger || Rails.logger
    end

    def call
      open_mrs = fetch_open_merge_requests
      return Result.new(merge_requests: open_mrs, error: false) if @query.empty?

      Result.new(merge_requests: matches(open_mrs), error: false)
    rescue StandardError => e
      @logger.warn("[deploy_review_search] failed to list MRs for #{@project_path}: #{e.class}: #{e.message}")
      Result.new(merge_requests: [], error: true)
    end

    private

    # `.auto_paginate` — same convention as the four list endpoints in
    # GitlabHelpers. Capping at one page is what hid 29 of 129 open MRs.
    def fetch_open_merge_requests
      @client.merge_requests(@project_path, state: 'opened', per_page: 100).auto_paginate
    end

    def matches(open_mrs)
      (open_mrs.select { |mr| text_match?(mr) } + related_matches(open_mrs))
        .uniq { |mr| field(mr, :iid) }
    end

    def text_match?(merge_request)
      haystack = [field(merge_request, :title), field(merge_request, :source_branch),
                  field(merge_request, :iid)].join(' ').downcase
      haystack.include?(needle)
    end

    def needle = @needle ||= @query.downcase.delete_prefix('#')

    def related_matches(open_mrs)
      iid = numeric_query
      return [] unless iid

      related = related_open_iids(iid)
      return [] if related.empty?

      open_mrs.select { |mr| related.include?(field(mr, :iid)) }
    end

    def numeric_query
      match = NUMERIC_QUERY.match(@query)
      match && Integer(match[1])
    end

    def related_open_iids(issue_iid)
      @client.related_merge_requests(@project_path, issue_iid)
             .select { |mr| field(mr, :state) == 'opened' }
             .map { |mr| field(mr, :iid) }
    rescue StandardError => e
      @logger.warn("[deploy_review_search] related MR lookup failed for #{@project_path}##{issue_iid}: " \
                   "#{e.class}: #{e.message}")
      []
    end

    def field(obj, name) = ::GitlabHelpers.field(obj, name)
  end
end
