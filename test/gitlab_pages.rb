# frozen_string_literal: true

require 'gitlab'

# A real `Gitlab::Client` whose one HTTP seam, `get`, serves a multi-page list
# answer (Autodev #116) — the shape `GitlabRequestCounterPaginationTest`
# already uses for the counter.
#
# Everything above `get` is the gem's own code: the named method
# (`issue_label_events` is a bare `get` of the list path in gitlab-5.1.0), the
# `Gitlab::PaginatedResponse` it returns, and `auto_paginate` → `next_page` →
# `client_relative_path` following GitLab's `Link: <…>; rel="next"` header back
# through the client. A stand-in whose `auto_paginate` hands every page over at
# once proves only that the code *called* it; this proves the call walks pages
# the way the production read does. Page N carries a `next` link exactly when a
# page N + 1 exists, which is how GitLab builds it.
class GitlabPagesClient < Gitlab::Client
  ENDPOINT = 'https://gitlab.example/api/v4'

  attr_reader :fetched

  # `fail_on_page:` raises `error` when that page is requested — an outage in
  # the middle of a walk, which must never leave the caller acting on the pages
  # it had already read.
  def initialize(pages, fail_on_page: nil, error: nil)
    super(endpoint: ENDPOINT, private_token: 'x')
    @pages = pages
    @fail_on_page = fail_on_page
    @error = error
    @fetched = []
  end

  def get(path, _options = {})
    number = Integer(path[/[?&]page=(\d+)/, 1] || 1)
    @fetched << number
    raise @error if number == @fail_on_page

    response = Gitlab::PaginatedResponse.new(@pages.fetch(number - 1))
    response.client = self
    response.parse_headers!(link_header(path, number))
    response
  end

  private

  def link_header(path, number)
    return {} if number >= @pages.size

    { 'Link' => %(<#{ENDPOINT}#{path.split('?').first}?id=1&page=#{number + 1}&per_page=20>; rel="next") }
  end
end
