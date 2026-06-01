# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/danger_claude_runner'
require 'autodev/pipeline_monitor'

# Regression: `merge_request_discussions` returns a Gitlab::PaginatedResponse with a default
# per_page of 20. Without auto_paginate, MRs with >20 timeline entries (commit notes, mentions,
# inline review threads…) silently drop the trailing discussions — observed on MR 10699 where
# 3 unresolved review threads at positions #21-#23 stayed open forever.
class PipelineMonitorFetchUnresolvedDiscussionsTest < Minitest::Test
  FakeNote = Struct.new(:resolvable, :resolved)
  FakeDiscussion = Struct.new(:id, :notes)

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

  class StubClient
    attr_reader :last_call

    def initialize(paginated:)
      @paginated = paginated
    end

    def merge_request_discussions(project_path, mr_iid, **opts)
      @last_call = { project_path: project_path, mr_iid: mr_iid, opts: opts }
      @paginated
    end
  end

  def setup
    @monitor = PipelineMonitor.allocate
    @monitor.instance_variable_set(:@project_path, 'group/project')
    @monitor.instance_variable_set(:@logger, StubLogger.new)
  end

  def test_discussions_past_first_page_are_returned
    paginated = two_page_fixture
    @monitor.instance_variable_set(:@client, StubClient.new(paginated: paginated))

    result = @monitor.send(:fetch_unresolved_discussions, 42)

    assert paginated.auto_paginate_called, 'fetch_unresolved_discussions must call auto_paginate'
    assert_equal ['trailing-unresolved'], result.map(&:id)
  end

  private

  def two_page_fixture
    page_one = Array.new(20) { |i| FakeDiscussion.new("page1-#{i}", [FakeNote.new(true, true)]) }
    page_two = [FakeDiscussion.new('trailing-unresolved', [FakeNote.new(true, false)])]
    FakePaginated.new([page_one, page_two])
  end
end
