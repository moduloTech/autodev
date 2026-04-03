# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/danger_claude_runner'
require 'autodev/pipeline_monitor'

class PipelineMonitorResolvedTest < Minitest::Test
  FakeNote = Struct.new(:resolvable, :resolved)
  FakeDiscussion = Struct.new(:notes)

  def setup
    @monitor = PipelineMonitor.allocate
  end

  def test_resolved_when_all_resolvable_notes_resolved
    discussion = FakeDiscussion.new([
                                      FakeNote.new(true, true),
                                      FakeNote.new(true, true)
                                    ])

    assert @monitor.send(:resolved?, discussion)
  end

  def test_not_resolved_when_any_resolvable_note_unresolved
    discussion = FakeDiscussion.new([
                                      FakeNote.new(true, true),
                                      FakeNote.new(true, false)
                                    ])

    refute @monitor.send(:resolved?, discussion)
  end

  def test_resolved_when_no_resolvable_notes
    discussion = FakeDiscussion.new([FakeNote.new(false, false)])

    assert @monitor.send(:resolved?, discussion)
  end

  def test_resolved_when_notes_empty
    discussion = FakeDiscussion.new([])

    assert @monitor.send(:resolved?, discussion)
  end

  def test_resolved_with_mixed_resolvable_and_non_resolvable
    discussion = FakeDiscussion.new([
                                      FakeNote.new(false, false),
                                      FakeNote.new(true, true)
                                    ])

    assert @monitor.send(:resolved?, discussion)
  end

  def test_not_resolved_with_single_unresolved_note
    discussion = FakeDiscussion.new([FakeNote.new(true, false)])

    refute @monitor.send(:resolved?, discussion)
  end

  def test_resolved_when_notes_lack_resolvable_method
    plain_note = Struct.new(:body).new('just a comment')
    discussion = FakeDiscussion.new([plain_note])

    assert @monitor.send(:resolved?, discussion)
  end
end
