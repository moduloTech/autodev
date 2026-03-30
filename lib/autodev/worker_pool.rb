# frozen_string_literal: true

class WorkerPool
  def initialize(size:, logger:)
    @size    = size
    @queue   = Queue.new
    @logger  = logger
    @threads = []
    @running = true
    @assignments = {} # worker index => issue_iid
    @mutex = Mutex.new
  end

  def start
    @threads = @size.times.map do |i|
      Thread.new do
        Thread.current.name = "worker-#{i}"
        while @running
          begin
            job, issue_iid = @queue.pop(true)
            @mutex.synchronize { @assignments[i] = issue_iid }
            job.call
          rescue ThreadError
            sleep 0.5
          rescue StandardError => e
            @logger.error("[worker-#{i}] Unhandled error: #{e.class}: #{e.message}")
          ensure
            @mutex.synchronize { @assignments.delete(i) }
          end
        end
      end
    end
  end

  def enqueue(issue_iid: nil, &block)
    @queue.push([block, issue_iid])
  end

  # Returns { worker_index => issue_iid } for busy workers
  def assignments
    @mutex.synchronize { @assignments.dup }
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
