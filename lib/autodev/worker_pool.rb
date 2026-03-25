# frozen_string_literal: true

class WorkerPool
  def initialize(size:, logger:)
    @size    = size
    @queue   = Queue.new
    @logger  = logger
    @threads = []
    @running = true
  end

  def start
    @threads = @size.times.map do |i|
      Thread.new do
        Thread.current.name = "worker-#{i}"
        while @running
          begin
            job = @queue.pop(true)
            job.call
          rescue ThreadError
            sleep 0.5
          rescue StandardError => e
            @logger.error("[worker-#{i}] Unhandled error: #{e.class}: #{e.message}")
          end
        end
      end
    end
  end

  def enqueue(&block)
    @queue.push(block)
  end

  def shutdown(timeout: 30)
    @running = false
    @size.times { @queue.push(-> {}) }
    @threads.each { |t| t.join(timeout) }
  end

  def busy?
    !@queue.empty?
  end
end
