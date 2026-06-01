# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/danger_claude_runner'
require 'autodev/mr_fixer'

# Companion to pipeline_monitor_fetch_unresolved_discussions_test.rb — same bug, second call site.
# MrFixer's fetch_unresolved_discussions also has to walk every page or it stops fixing trailing
# threads on busy MRs.
class MrFixerFetchUnresolvedDiscussionsTest < Minitest::Test
  FakeNote = Struct.new(:resolvable, :resolved, :body)
  FakeDiscussion = Struct.new(:id, :notes)

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
    @fixer = MrFixer.allocate
    @fixer.instance_variable_set(:@project_path, 'group/project')
    @fixer.instance_variable_set(:@logger, StubLogger.new)
  end

  def test_discussions_past_first_page_are_returned
    paginated = two_page_fixture
    @fixer.instance_variable_set(:@client, StubClient.new(paginated: paginated))

    result = @fixer.send(:fetch_unresolved_discussions, 42)

    assert paginated.auto_paginate_called, 'fetch_unresolved_discussions must call auto_paginate'
    assert_equal(['trailing-unresolved'], result.map { |d| d[:id] })
  end

  private

  def two_page_fixture
    page_one = Array.new(20) { |i| FakeDiscussion.new("p1-#{i}", [FakeNote.new(true, true, 'done')]) }
    note = FakeNote.new(true, false, 'please fix the trailing thread')
    page_two = [FakeDiscussion.new('trailing-unresolved', [note])]
    FakePaginated.new([page_one, page_two])
  end
end
