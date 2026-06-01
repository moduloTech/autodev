# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'

# Regression: the gitlab gem returns a Gitlab::PaginatedResponse from list endpoints.
# Without .auto_paginate (or a per_page > result count), only the first page is materialised.
# Several call sites in gitlab_helpers used to rely on the default per_page=20 or capped at 100
# without walking pages, which caused two distinct symptoms in production:
#   - clarification_answered? could miss a reply hiding past note #100, leaving an issue
#     stuck in needs_clarification forever
#   - fetch_mr_discussions_context handed a truncated review history to danger-claude,
#     so the model fixed only the threads visible on page 1
class GitlabHelpersPaginationTest < Minitest::Test
  # Mimics Gitlab::PaginatedResponse: behaves like the first page (Array) but reveals
  # the rest only through auto_paginate, so a regression that drops auto_paginate
  # would lose the trailing pages.
  class FakePaginated
    attr_reader :auto_paginate_called

    def initialize(pages)
      @pages = pages
      @first_page = pages.first
      @auto_paginate_called = false
    end

    def auto_paginate
      @auto_paginate_called = true
      @pages.flatten(1)
    end

    def method_missing(name, *, &)
      @first_page.send(name, *, &)
    end

    def respond_to_missing?(name, include_private = false)
      @first_page.respond_to?(name, include_private) || super
    end
  end

  FakeNote = Struct.new(:body, :system, :created_at, :author)
  FakeDiscussion = Struct.new(:notes)

  def test_clarification_answered_sees_reply_past_first_page
    requested_at = '2026-01-01T00:00:00Z'
    page_one = Array.new(100) { |i| build_system_note(i) }
    user_reply = FakeNote.new(body: 'here is my answer', system: false,
                              created_at: '2026-02-01T00:00:00Z', author: nil)
    paginated = FakePaginated.new([page_one, [user_reply]])
    client = stub_client(issue_notes: paginated)

    assert GitlabHelpers.clarification_answered?(client, 'group/project', 1, requested_at),
           'clarification reply on page 2 must still be detected'
    assert paginated.auto_paginate_called
  end

  def test_fetch_mr_discussions_context_includes_trailing_pages
    page_one = Array.new(20) { build_review_discussion('resolved feedback') }
    page_two = [build_review_discussion('trailing feedback past page 1')]
    paginated = FakePaginated.new([page_one, page_two])
    client = stub_client(merge_request_discussions: paginated)

    context = GitlabHelpers.fetch_mr_discussions_context(client, 'group/project', 42)

    assert paginated.auto_paginate_called
    assert_includes context, 'trailing feedback past page 1',
                    'context must include discussions past the default per_page boundary'
  end

  private

  def build_system_note(idx)
    FakeNote.new(body: "system note #{idx}", system: true, created_at: '2026-01-01T00:00:00Z', author: nil)
  end

  def build_review_discussion(body)
    author = Struct.new(:name).new('reviewer')
    note = Struct.new(:body, :author, :created_at, :resolvable, :resolved, :position)
                 .new(body, author, '2026-01-01T00:00:00Z', true, false, nil)
    FakeDiscussion.new([note])
  end

  def stub_client(stubs)
    client = Object.new
    stubs.each do |method, value|
      client.define_singleton_method(method) { |*_args, **_kwargs| value }
    end
    client
  end
end
