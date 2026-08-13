# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/danger_claude_runner'
require 'autodev/mr_fixer'

# Companion to pipeline_monitor_fetch_unresolved_discussions_test.rb. The fetch itself is one
# method shared by both callers since Autodev #62 (`MrDiscussions`) — there used to be two
# byte-for-byte copies, which is how one of them ended up answering a GitLab error with `[]` on the
# delivery path. What is MrFixer's own is the *shape*: the title and notes it builds a prompt from,
# mapped over the shared list. Both halves are pinned here, from MrFixer's side: every page is
# walked (MR 10699 had three unresolved threads at positions #21-#23 that stayed open forever), and
# each surviving thread arrives as the hash `fix_each_discussion` expects.
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

    result = unresolved_as_mr_fixer_sees_them

    assert paginated.auto_paginate_called, 'fetch_unresolved_discussions must call auto_paginate'
    assert_equal(['trailing-unresolved'], result.map { |d| d[:id] })
  end

  def test_each_thread_arrives_in_the_shape_the_fix_cycle_expects
    @fixer.instance_variable_set(:@client, StubClient.new(paginated: two_page_fixture))

    thread = unresolved_as_mr_fixer_sees_them.first

    assert_equal 'trailing-unresolved', thread[:id]
    assert_equal 'please fix the trailing thread', thread[:title]
    refute_empty thread[:notes]
  end

  private

  # `MrFixer#fix` reads the shared list and maps its own shape over it.
  def unresolved_as_mr_fixer_sees_them
    @fixer.send(:fetch_unresolved_discussions, 42).map { |d| @fixer.send(:build_discussion, d) }
  end

  def two_page_fixture
    page_one = Array.new(20) { |i| FakeDiscussion.new("p1-#{i}", [FakeNote.new(true, true, 'done')]) }
    note = FakeNote.new(true, false, 'please fix the trailing thread')
    page_two = [FakeDiscussion.new('trailing-unresolved', [note])]
    FakePaginated.new([page_one, page_two])
  end
end
