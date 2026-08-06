# frozen_string_literal: true

require_relative '../../rails_helper'

# Autodev::DeployReviewSearch — finding the MR to deploy from what a CSM
# actually has in hand (Autodev #45).
#
# The reported symptom was "these Ready-for-QA tickets can't be deployed". The
# three MRs were in fact perfectly deployable; what was missing was any way to
# get from a *ticket* number to its *merge request*. `/deploy_review` listed
# every open MR (129 on powerpanne/core, of which 118 already tracked) with no
# search, and capped the fetch at one page of 100 — so 29 were unreachable
# outright.
class DeployReviewSearchTest < ActiveSupport::TestCase
  MergeRequest = Struct.new(:iid, :title, :source_branch, :state)

  # Mimics Gitlab::PaginatedResponse: only `auto_paginate` reveals every page,
  # so dropping it loses the tail (same stand-in idea as
  # test/gitlab_helpers_pagination_test.rb).
  class FakePaginated
    def initialize(pages)
      @pages = pages
    end

    def auto_paginate = @pages.flatten(1)
    def to_a = @pages.first
  end

  class FakeClient
    attr_reader :related_calls

    def initialize(pages: [[]], related: {}, raise_on_list: false, raise_on_related: false)
      @pages = pages
      @related = related
      @raise_on_list = raise_on_list
      @raise_on_related = raise_on_related
      @related_calls = []
    end

    def merge_requests(_project_path, _opts = {})
      raise StandardError, 'boom' if @raise_on_list

      FakePaginated.new(@pages)
    end

    def related_merge_requests(_project_path, issue_iid)
      raise StandardError, 'boom' if @raise_on_related

      @related_calls << issue_iid
      @related.fetch(issue_iid, [])
    end
  end

  # The real shapes from the reported cases.
  def open_mr(iid, title, branch) = MergeRequest.new(iid: iid, title: title, source_branch: branch, state: 'opened')

  def mrs
    [open_mr(11_203, 'Distinguish stolen or broken wheels', '15966-distinguish-stolen-or-broken-wheels'),
     open_mr(11_292, 'On delivery site driver GPS', '16432-on-delivery-site-driver-gps'),
     open_mr(11_284, 'Dispatch vue refactor', '16295-dispatch-vue-refact')]
  end

  def search(query, client)
    Autodev::DeployReviewSearch.new(client: client, project_path: 'group/proj',
                                    query: query, logger: Logger.new(IO::NULL)).call
  end

  def found_iids(query, client) = search(query, client).merge_requests.map(&:iid)

  # --- pagination ---------------------------------------------------------

  # 129 open MRs, per_page 100, no pagination ⇒ 29 silently unreachable.
  test 'every page of open MRs is fetched, not just the first' do
    page1 = Array.new(100) { |i| open_mr(1000 + i, "MR #{i}", "branch-#{i}") }
    page2 = Array.new(29) { |i| open_mr(2000 + i, "MR #{i}", "tail-#{i}") }
    result = search(nil, FakeClient.new(pages: [page1, page2]))

    assert_equal 129, result.merge_requests.size
  end

  test 'an MR past the first page is findable' do
    page1 = Array.new(100) { |i| open_mr(1000 + i, "MR #{i}", "branch-#{i}") }
    page2 = [open_mr(2001, 'Tail MR', '16432-tail')]

    assert_equal [2001], found_iids('16432', FakeClient.new(pages: [page1, page2]))
  end

  # --- no query -----------------------------------------------------------

  test 'a blank query returns every open MR' do
    assert_equal 3, search(nil, FakeClient.new(pages: [mrs])).merge_requests.size
  end

  test 'a whitespace-only query is treated as blank' do
    assert_equal 3, search('   ', FakeClient.new(pages: [mrs])).merge_requests.size
  end

  # --- text matching ------------------------------------------------------

  # The branch convention `<ticket-iid>-<slug>` covers the common case without
  # any extra GitLab call.
  test 'a ticket number matches the branch that carries it' do
    assert_equal [11_292], found_iids('16432', FakeClient.new(pages: [mrs]))
  end

  test 'a leading hash is accepted' do
    assert_equal [11_292], found_iids('#16432', FakeClient.new(pages: [mrs]))
  end

  test 'an MR number matches its own iid' do
    assert_equal [11_203], found_iids('11203', FakeClient.new(pages: [mrs]))
  end

  test 'free text matches the title, case-insensitively' do
    assert_equal [11_203], found_iids('STOLEN', FakeClient.new(pages: [mrs]))
  end

  test 'free text matches the branch' do
    assert_equal [11_284], found_iids('dispatch-vue', FakeClient.new(pages: [mrs]))
  end

  test 'no match returns an empty list, not everything' do
    assert_empty found_iids('nothing-like-this', FakeClient.new(pages: [mrs]))
  end

  # --- related merge requests --------------------------------------------

  # The case the branch convention cannot cover: ticket #16294's own MR was
  # merged, and the open MR that carries its work is named after a *different*
  # ticket. Only GitLab knows the link.
  test 'a ticket number also resolves through GitLabs related merge requests' do
    client = FakeClient.new(pages: [mrs], related: { 16_294 => [MergeRequest.new(iid: 11_284, state: 'opened')] })

    assert_equal [11_284], found_iids('16294', client)
  end

  test 'a related MR that is no longer open is not offered' do
    client = FakeClient.new(pages: [mrs], related: { 16_294 => [MergeRequest.new(iid: 11_260, state: 'merged')] })

    assert_empty found_iids('16294', client)
  end

  test 'text matches and related matches are merged without duplicates' do
    client = FakeClient.new(pages: [mrs], related: { 16_432 => [MergeRequest.new(iid: 11_292, state: 'opened')] })

    assert_equal [11_292], found_iids('16432', client)
  end

  test 'the related lookup is skipped for a non-numeric query' do
    client = FakeClient.new(pages: [mrs])
    search('stolen', client)

    assert_empty client.related_calls
  end

  # A ticket with no related MR must not silently fall back to "everything".
  test 'a numeric query with neither text nor related match returns nothing' do
    assert_empty found_iids('99999', FakeClient.new(pages: [mrs]))
  end

  # --- degradation --------------------------------------------------------

  # The related lookup is an enhancement: losing it must not lose the text
  # matches the CSM would otherwise have got.
  test 'a failing related lookup degrades to the text match' do
    client = FakeClient.new(pages: [mrs], raise_on_related: true)

    assert_equal [11_292], found_iids('16432', client)
  end

  test 'a failing MR list reports an error rather than an empty list' do
    result = search(nil, FakeClient.new(raise_on_list: true))

    assert result.error
    assert_empty result.merge_requests
  end

  test 'a successful search reports no error' do
    refute search('16432', FakeClient.new(pages: [mrs])).error
  end
end
