# frozen_string_literal: true

class PipelineMonitor
  # What makes two failures of the same CI job "the same failure" (Autodev #130).
  #
  # The job's name does not. Measured on the 318 pipeline-fix rounds production
  # recorded up to 08/10/2026: 42 failed a job that was also red, by name, on the
  # target branch at that moment, and only 6 of those 42 carry a failure the
  # target accounts for. In 7 the failure is demonstrably another one — on
  # 01/07, powerpanne 15349's `test` failed three spec examples while `staging`'s
  # `test` had stopped after 46 seconds naming no failed example — and the other 29 cannot
  # be compared at all, their traces being truncated. Read by name, all 36 would
  # have been left unfixed.
  #
  # Two facts about the traces decided the rule. powerpanne's test jobs regularly
  # exceed GitLab's 4 MiB trace limit, and the tail of a truncated trace is the
  # middle of the run, so a truncated trace has no signature at all. And no
  # project exposes a JUnit report, so the failed examples are read off the trace.
  #
  # Every unknown answers "not comparable", which keeps the job on the merge
  # request's side and fixed as before this ticket. That is the cheap error: the
  # other one leaves unfixed a failure the merge request introduced.
  module FailureSignature
    TRUNCATION_MARKER = "Job's log exceeded limit"
    # `2026-09-16T14:56:53.808621Z 01O ` — the runner's timestamp and stream code,
    # `+` marking a continuation.
    RUNNER_PREFIX = /\A\d{4}-\d\d-\d\dT[\d:.]+Z \d+[OE]\+? ?/
    ANSI_ESCAPE = /\e\[[0-9;]*[A-Za-z]/
    # rspec's "Failed examples:" list and minitest's rerun lines.
    FAILED_EXAMPLE = %r{\A(?:rspec|(?:bin/)?rails test) (\S+:\d+)}
    # The Kubernetes executor interleaves scheduling events into the job's output.
    RUNNER_NOISE = 'WARNING: Event retrieved from the cluster'
    TAIL_SIZE = 5

    module_function

    # `nil` (no signature), `[:examples, Set<"path:line">]` or `[:tail, Array<String>]`.
    def of(trace)
      text = trace.to_s
      return nil if text.include?(TRUNCATION_MARKER)

      script = script_lines(text)
      examples = script.filter_map { |line| line[FAILED_EXAMPLE, 1] }
      return [:examples, examples.to_set] unless examples.empty?

      tail = tail_of(script)
      tail.empty? ? nil : [:tail, tail]
    end

    # Whether the target's failure accounts for the merge request's. Failed
    # examples: the merge request broke nothing the target had not already broken
    # (a subset — one more failing example is the merge request's own). Otherwise
    # the last lines must be the same.
    def explains?(target_signature, mr_signature)
      return false if target_signature.nil? || mr_signature.nil?
      return false unless target_signature.first == mr_signature.first

      if mr_signature.first == :examples
        mr_signature.last.subset?(target_signature.last)
      else
        mr_signature.last == target_signature.last
      end
    end

    # The job's own script only: what the runner writes after it (artifact
    # upload, cleanup, its exit line) is the same for every failure. A trace with
    # no marker is read whole.
    def script_lines(text)
      lines = text.split("\n").map { |line| line.sub(RUNNER_PREFIX, '').gsub(ANSI_ESCAPE, '').delete("\r") }
      script_end = lines.rindex { |line| line.include?('section_end:') && line.include?(':step_script') }
      script_end ? lines[0...script_end] : lines
    end

    def tail_of(lines)
      lines.map(&:strip)
           .reject { |line| line.empty? || line.start_with?(RUNNER_NOISE) || line.start_with?('section_') }
           .last(TAIL_SIZE)
           .map { |line| line.gsub(/\h{7,}/, 'H').gsub(/\d+/, 'N') }
    end
  end
end
