# frozen_string_literal: true

require 'set'

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
        while @running
          begin
            job, issue_iid = @queue.pop(true)
            @mutex.synchronize do
              @assignments[i] = issue_iid
              # iid stays in @queued_iids until the job finishes
            end
            persist_assignments
            job.call
          rescue ThreadError
            sleep 0.5
          rescue StandardError => e
            @logger.error("[worker-#{i}] Unhandled error: #{e.class}: #{e.message}")
          ensure
            @mutex.synchronize do
              @queued_iids.delete(@assignments[i])
              @assignments.delete(i)
            end
            persist_assignments
          end
        end
      end
    end
  end

  # Returns false if the issue is already queued or being processed
  def enqueue(issue_iid: nil, &block)
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

  def persist_assignments
    mapping = @mutex.synchronize { @assignments.dup }
    File.write(ASSIGNMENTS_FILE, JSON.generate(mapping))
  rescue StandardError
    # Non-critical, ignore write errors
  end
end
