# frozen_string_literal: true

# Thread pool that distributes issue processing across N concurrent workers.
class WorkerPool
  ASSIGNMENTS_FILE = File.expand_path('~/.autodev/workers.json')

  def initialize(size:, logger:)
    @size    = size
    @queue   = Queue.new
    @logger  = logger
    @threads = []
    @running = true
    @assignments = {} # worker index => issue_iid
    @queued_iids = Set.new # issue_iids in queue or being processed
    @mutex = Mutex.new
  end

  def start
    @threads = @size.times.map do |i|
      Thread.new do
        Thread.current.name = "worker-#{i}"
        run_worker_loop(i)
      end
    end
  end

  # Returns false if the issue is already queued or being processed
  def enqueue?(issue_iid: nil, &block)
    @mutex.synchronize do
      return false if issue_iid && @queued_iids.include?(issue_iid)

      @queued_iids.add(issue_iid) if issue_iid
    end
    @queue.push([block, issue_iid])
    true
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

  # Read persisted assignments (usable from other processes, e.g. --status)
  def self.read_assignments
    return {} unless File.exist?(ASSIGNMENTS_FILE)

    data = JSON.parse(File.read(ASSIGNMENTS_FILE))
    # Convert string keys back to integers
    data.transform_keys(&:to_i)
  rescue JSON::ParserError, Errno::ENOENT
    {}
  end

  def cleanup
    FileUtils.rm_f(ASSIGNMENTS_FILE)
  rescue Errno::ENOENT
    # ignore
  end

  private

  def run_worker_loop(index)
    while @running
      run_next_job(index)
    end
  end

  def run_next_job(index)
    job, issue_iid = @queue.pop(true)
    @mutex.synchronize { @assignments[index] = issue_iid }
    persist_assignments
    job.call
  rescue ThreadError
    sleep 0.5
  rescue StandardError => e
    @logger.error("[worker-#{index}] Unhandled error: #{e.class}: #{e.message}")
  ensure
    release_worker(index)
  end

  def release_worker(index)
    @mutex.synchronize do
      @queued_iids.delete(@assignments[index])
      @assignments.delete(index)
    end
    persist_assignments
  end

  def persist_assignments
    mapping = @mutex.synchronize { @assignments.dup }
    File.write(ASSIGNMENTS_FILE, JSON.generate(mapping))
  rescue StandardError
    # Non-critical, ignore write errors
  end
end
