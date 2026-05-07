# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/web'

class WebEventBusTest < Minitest::Test
  def setup
    Web::EventBus.reset!
  end

  def test_publish_delivers_to_subscriber
    queue = Web::EventBus.subscribe
    Web::EventBus.publish(:hello)

    assert_equal :hello, queue.pop
  end

  def test_publish_fans_out_to_multiple_subscribers
    q1 = Web::EventBus.subscribe
    q2 = Web::EventBus.subscribe
    Web::EventBus.publish(:event)

    assert_equal :event, q1.pop
    assert_equal :event, q2.pop
  end

  def test_unsubscribe_stops_delivery
    queue = Web::EventBus.subscribe
    Web::EventBus.unsubscribe(queue)
    Web::EventBus.publish(:nope)

    assert_predicate queue, :empty?
  end

  def test_shutdown_pushes_sentinel_to_each_subscriber
    queue = Web::EventBus.subscribe
    Web::EventBus.shutdown!

    assert_equal Web::EventBus::SHUTDOWN_SENTINEL, queue.pop
  end

  def test_backpressure_drops_oldest_when_queue_overflows
    queue = Web::EventBus.subscribe
    (Web::EventBus::QUEUE_HIGH_WATER_MARK + 5).times { |i| Web::EventBus.publish(i) }

    assert_operator queue.size, :<=, Web::EventBus::QUEUE_HIGH_WATER_MARK
  end
end
