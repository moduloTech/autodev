# frozen_string_literal: true

module Web
  # Thread-safe in-process pub/sub used to push activity_events and
  # AASM transitions to SSE subscribers (one Queue per HTTP client).
  #
  # Single-process, single-Ruby-VM. No persistence; if no client is
  # subscribed, events are dropped — the DB row is the source of truth.
  module EventBus
    SHUTDOWN_SENTINEL = :__shutdown__
    QUEUE_HIGH_WATER_MARK = 100

    @mutex = Mutex.new
    @subscribers = []

    class << self
      attr_reader :mutex, :subscribers

      def subscribe
        q = Queue.new
        mutex.synchronize { subscribers << q }
        q
      end

      def unsubscribe(queue)
        mutex.synchronize { subscribers.delete(queue) }
      end

      def publish(event)
        snapshot = mutex.synchronize { subscribers.dup }
        snapshot.each { |q| push_with_backpressure(q, event) }
      end

      # Signal every subscriber to stop (used at server shutdown). Idempotent.
      def shutdown!
        snapshot = mutex.synchronize { subscribers.dup }
        snapshot.each { |q| q << SHUTDOWN_SENTINEL }
      end

      def reset!
        mutex.synchronize { subscribers.clear }
      end

      private

      # Drop the oldest event when a slow subscriber's queue grows past the
      # watermark — better than blocking publishers or letting RAM balloon.
      def push_with_backpressure(queue, event)
        queue.pop(true) while queue.size >= QUEUE_HIGH_WATER_MARK
        queue << event
      rescue ThreadError
        queue << event
      end
    end
  end
end
