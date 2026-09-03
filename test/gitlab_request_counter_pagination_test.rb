# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'
require 'gitlab'

# Autodev #96 counts every GitLab request through a proxy around the client
# `GitlabHelpers.build_gitlab_client` returns. Two defects were found in that
# proxy by the two neutral reviews of the alpha-53 lot, and they were opposite:
#
#   * the first: `auto_paginate`'s pages 2..N escaped the count entirely,
#     because the gem builds its `Gitlab::PaginatedResponse` with
#     `parsed.client = self` — the raw client, not the proxy;
#   * the second: the fix for that made the count too *high*, because
#     `PaginatedResponse#client_relative_path` reads `@client.endpoint` on
#     every page turn and the proxy recorded a stat for any message at all.
#
# So the property worth pinning is not "pages are counted" but **the count
# equals the number of HTTP requests actually issued**, which is what an
# operator reading `gitlab_requests` believes it is. This file asserts it
# against the real gem's pagination machinery rather than a stand-in.
class GitlabRequestCounterPaginationTest < Minitest::Test
  include DatabaseTestHelper

  # A `Gitlab::Client` whose `get` is counted by hand, so the test has an
  # independent measure of "HTTP requests issued" to compare the proxy's
  # tally against. Everything else is the real class, including
  # `Gitlab::Configuration`'s accessors.
  class CountingClient < Gitlab::Client
    attr_reader :gets

    def initialize(...)
      super
      @gets = []
    end

    def get(path, _options = {})
      @gets << path
      page_for(path)
    end

    private

    # Three pages, linked through the gem's own `Link`-header parser
    # (`parse_headers!` → `Headers::PageLinks`) rather than by poking at
    # `@links`, so the page turn goes through the real machinery — which is
    # the whole point: it is that machinery that reads `@client.endpoint` and
    # calls `@client.get`.
    def page_for(path)
      index = path[/page=(\d+)/, 1].to_i
      index = 1 if index.zero?
      build_page(index)
    end

    def build_page(index)
      response = Gitlab::PaginatedResponse.new([{ 'id' => index }])
      response.client = self
      response.parse_headers!(link_headers(index))
      response
    end

    def link_headers(index)
      return {} if index >= 3

      { 'Link' => "<https://gitlab.example/api/v4/things?page=#{index + 1}>; rel=\"next\"" }
    end
  end

  def setup
    setup_database
    @client = CountingClient.new(endpoint: 'https://gitlab.example/api/v4', private_token: 'x')
    @proxy = GitlabRequestCounter.new(@client)
  end

  def test_the_count_equals_the_number_of_http_requests_for_a_paginated_read
    rows = @proxy.get('/api/v4/things').auto_paginate

    assert_equal 3, rows.size, 'precondition: the fixture must really paginate'
    assert_equal 3, @client.gets.size, 'precondition: three HTTP requests were issued'
    assert_equal 3, counted_requests, 'the tally must equal the requests, not exceed them'
  end

  def test_the_pages_after_the_first_are_counted_at_all
    @proxy.get('/api/v4/things').auto_paginate

    assert_operator counted_requests, :>, 1,
                    'pages 2..N used to escape the proxy entirely (first review, G4)'
  end

  def test_the_gems_configuration_accessors_are_not_counted_as_requests
    # `endpoint` is read once per page turn and issues nothing. Counting it
    # both inflated the total and put a bogus `endpoint` row in the
    # per-endpoint breakdown (second review, N3).
    @proxy.endpoint
    @proxy.private_token

    assert_equal 0, counted_requests
    assert_empty GitlabRequestStat.where(endpoint: 'endpoint')
  end

  def test_a_plain_read_is_still_counted_once
    @proxy.get('/api/v4/version')

    assert_equal 1, counted_requests
  end

  private

  def counted_requests = GitlabRequestStat.sum(:count)
end
