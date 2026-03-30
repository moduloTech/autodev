# frozen_string_literal: true

class WorkerPool
  ASSIGNMENTS_FILE = File.expand_path("~/.autodev/workers.json")

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
            persist_assignments
            job.call
          rescue ThreadError
            sleep 0.5
          rescue StandardError => e
            @logger.error("[worker-#{i}] Unhandled error: #{e.class}: #{e.message}")
          ensure
            @mutex.synchronize { @assignments.delete(i) }
            persist_assignments
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
    File.delete(ASSIGNMENTS_FILE) if File.exist?(ASSIGNMENTS_FILE)
  rescue Errno::ENOENT
    # ignore
  end

  private

  def persist_assignments
    mapping = @mutex.synchronize { @assignments.dup }
    File.write(ASSIGNMENTS_FILE, JSON.generate(mapping))
  rescue StandardError
    # Non-critical, ignore write errors
  end
end
