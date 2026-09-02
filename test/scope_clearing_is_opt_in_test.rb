# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/label_manager'

# Autodev #98, review of the alpha-52 lot — clearing autodev's label scope
# **destroys the only evidence** that a human took the ticket back, so it may only
# happen on a path that has already asked whether they did.
#
# `LabelHandover#suspect` reads exactly one thing to answer "somebody moved this
# on": a value sitting in autodev's scope that is none of the configured four
# (`foreign_scoped(labels).first` → `:workflow_moved`). #98 made
# `manage_labels` remove that value on **every** write, which is right for the
# arrears sweep and wrong everywhere else.
#
# The path that showed it, on powerpanne:
#
#   1. a request is in `error`;
#   2. a human moves the ticket from `Development::Doing` to
#      `Development::Awaiting CR` to take it back, without reassigning;
#   3. `error` is not in `PollDispatcher::ACTIVE_STATUSES`, so
#      `dispatch_unassignment` never looks at the row — and it runs before
#      `dispatch_retries` in the cycle anyway;
#   4. `:retry_errored` → `restore_working_label` → `apply_label_doing` removes
#      `Awaiting CR` and poses `Doing`;
#   5. the row becomes `checking_pipeline`, so it is active from now on;
#   6. the next `dispatch_unassignment` finds no foreign value left, and the
#      handover is never detected. Autodev keeps working a ticket a human claimed.
#
# Before #98 the label survived the write and the next cycle closed the row with a
# handover comment.
#
# So the clearing is opt-in, and exactly one caller opts in:
# `PollRouter#repose_working_label`, whose only caller is `ReviewArrearsSweep` —
# the one path that asks `untouched_since_giveup?` (no human comment on the
# ticket, no human note on the merge request, no workflow label moved since)
# *before* it writes. There, the question has been put and answered; everywhere
# else it has not been asked.
class ScopeClearingIsOptInTest < Minitest::Test
  PATH = 'group/project'
  DOING = 'Development::Doing'
  MOVED_ON = 'Development::Awaiting CR'
  TODO = 'Development::ToDo'

  # ff/fast/core's real shape, read off the projects table on 02/09/2026: its only
  # entry label is scoped, and in autodev's own scope.
  CONFIG = { 'path' => PATH, 'labels_todo' => [TODO], 'label_doing' => DOING,
             'label_done' => 'Development::Done' }.freeze

  FakeIssue = Struct.new(:labels)

  # `labels` is the fact these tests read: asserting on the *write* would miss the
  # case where `manage_labels` correctly writes nothing because nothing would
  # change, which is one of them.
  class FakeClient
    attr_reader :writes, :labels

    def initialize(labels) = (@labels = labels.dup) && (@writes = [])

    def issue(_path, _iid) = FakeIssue.new(@labels)

    def edit_issue(_path, _iid, **opts)
      @writes << opts
      @labels = opts[:labels].split(',') if opts[:labels]
      nil
    end
  end

  def host(labels)
    client = FakeClient.new(labels)
    obj = Object.new
    obj.singleton_class.include(LabelManager)
    obj.instance_variable_set(:@client, client)
    obj.instance_variable_set(:@project_config, CONFIG)
    obj.instance_variable_set(:@project_path, PATH)
    obj.instance_variable_set(:@logger, nil)
    obj.define_singleton_method(:log) { |*| nil }
    obj.define_singleton_method(:log_error) { |*| nil }
    [obj, client]
  end

  # The regression, at its smallest: the ordinary write must leave the evidence.
  def test_an_ordinary_working_label_write_leaves_the_foreign_value_alone
    obj, client = host([MOVED_ON])

    obj.send(:apply_label_doing, 42)

    assert_includes client.labels, MOVED_ON
  end

  # And the sweep's write clears it, which is what #98 exists for — the ticket
  # showing two values of one scope, measured on powerpanne/core#16224.
  def test_the_swept_write_clears_the_foreign_value
    obj, client = host([MOVED_ON])

    obj.send(:apply_label_doing, 42, clear_scope: true)

    refute_includes client.labels, MOVED_ON
    assert_includes client.labels, DOING
  end

  # Even opted in, the clearing is confined to the labels autodev **owns**. The
  # justification #98 wrote for the old guard — "reposing the entry label is not a
  # claim over `Development::*`" — assumed the entry label sits outside the scope.
  # It does not: ff/fast/core declares `Development::ToDo` and nothing else, and on
  # powerpanne `entry_todo_label` answers whichever value the request arrived
  # under, which is `Development::ToDo` for every request entered by that column.
  # So a scope test would have wiped a reviewer's column while autodev parks the
  # request in `needs_clarification` — waiting on that very reviewer.
  def test_reposing_the_entry_label_never_clears_the_scope
    obj, client = host([TODO, MOVED_ON])

    obj.send(:apply_label_todo, 42)

    assert_includes client.labels, MOVED_ON
  end
end
