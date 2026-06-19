# frozen_string_literal: true

module Autodev
  # Discards Solid Queue failed jobs whose failure is a transient process
  # lifecycle event rather than an application bug. When a worker is pruned or
  # exits (the box slept, the supervisor restarted), Solid Queue marks its
  # in-flight jobs failed with these errors — but no work is lost: a pruned
  # `check_pipeline` issue is re-dispatched on the next poll, and
  # AutodevPollJob is recurring. Left alone they pile up in the "Failed" tab
  # (which the finished-jobs cleanup doesn't touch) and read as a real outage.
  #
  # Only these infra error classes are discarded — any other exception class
  # is a genuine application failure and stays visible.
  class FailedJobReaper
    TRANSIENT_ERRORS = %w[
      SolidQueue::Processes::ProcessPrunedError
      SolidQueue::Processes::ProcessExitError
    ].freeze

    def self.run
      new.run
    end

    # Returns the number of failed executions discarded.
    def run
      candidates.select { |fe| TRANSIENT_ERRORS.include?(fe.exception_class) }
                .each { |fe| safe_discard(fe) }
                .count(&:destroyed?)
    end

    private

    # SQL prefilter (the error JSON embeds the class name) so we don't load
    # every failed execution; the exact class match happens in Ruby.
    def candidates
      SolidQueue::FailedExecution.where('error LIKE ?', '%SolidQueue::Processes::Process%').to_a
    end

    def safe_discard(failed_execution)
      failed_execution.discard
    rescue StandardError
      nil
    end
  end
end
