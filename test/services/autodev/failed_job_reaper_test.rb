# frozen_string_literal: true

require_relative '../../rails_helper'

module Autodev
  # Unit coverage for the reaper's orchestration: which failures it discards
  # and the count it reports. The Solid Queue query itself (`candidates`) is
  # stubbed — the test queue DB doesn't carry the solid_queue schema, and
  # `exception_class` / `discard` are gem-provided. We exercise the
  # transient-vs-real discrimination + discard + count.
  class FailedJobReaperTest < ActiveSupport::TestCase
    # Stands in for a SolidQueue::FailedExecution.
    class FakeFailed
      attr_reader :exception_class

      def initialize(exception_class)
        @exception_class = exception_class
        @destroyed = false
      end

      def discard
        @destroyed = true
      end

      def destroyed?
        @destroyed
      end
    end

    def reap(fakes)
      reaper = FailedJobReaper.new
      count = reaper.stub(:candidates, fakes) { reaper.run }
      [count, fakes]
    end

    test 'discards pruned-process and process-exit failures' do
      pruned = FakeFailed.new('SolidQueue::Processes::ProcessPrunedError')
      exited = FakeFailed.new('SolidQueue::Processes::ProcessExitError')

      count, = reap([pruned, exited])

      assert_equal 2, count
      assert_predicate pruned, :destroyed?
      assert_predicate exited, :destroyed?
    end

    test 'keeps genuine application failures' do
      runtime = FakeFailed.new('RuntimeError')

      count, = reap([runtime])

      assert_equal 0, count
      refute_predicate runtime, :destroyed?
    end

    test 'discards only the transient ones when both kinds are present' do
      pruned = FakeFailed.new('SolidQueue::Processes::ProcessPrunedError')
      bug = FakeFailed.new('NoMethodError')

      count, = reap([pruned, bug])

      assert_equal 1, count
      refute_predicate bug, :destroyed?
    end
  end
end
