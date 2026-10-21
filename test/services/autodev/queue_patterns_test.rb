# frozen_string_literal: true

require_relative '../../rails_helper'

module Autodev
  # Solid Queue's queue-matching rule, as the `workers` health card and the
  # served-queues test read it (Autodev #139).
  class QueuePatternsTest < ActiveSupport::TestCase
    test '* serves every queue' do
      assert QueuePatterns.serves?(['*'], 'poll')
      assert QueuePatterns.serves?(['*'], 'default')
    end

    test 'a prefix serves the queues it starts, and only those' do
      assert QueuePatterns.serves?(['poll*'], 'poll')
      assert QueuePatterns.serves?(['poll*'], 'polling')
      refute QueuePatterns.serves?(['poll*'], 'default')
    end

    test 'an exact name serves that queue alone' do
      assert QueuePatterns.serves?(%w[default solid_queue_recurring], 'default')
      refute QueuePatterns.serves?(%w[default solid_queue_recurring], 'poll')
      refute QueuePatterns.serves?(['pol'], 'poll')
    end

    test 'no pattern serves nothing' do
      refute QueuePatterns.serves?([], 'default')
    end
  end
end
