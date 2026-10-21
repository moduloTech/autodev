# frozen_string_literal: true

module Autodev
  # Whether a Solid Queue worker's `queues:` list serves a queue, by the rule
  # of Solid Queue's own `QueueSelector`: `prefix*` every queue with that
  # prefix — `*` being the empty prefix, every queue — anything else the exact
  # name (Autodev #139). Read by
  # the `workers` health card, on the lists the workers record in their
  # metadata, and by the test that every queue a job can land on is served.
  module QueuePatterns
    module_function

    def serves?(patterns, queue)
      queue = queue.to_s
      patterns.map(&:to_s).any? do |pattern|
        pattern == queue || (pattern.end_with?('*') && queue.start_with?(pattern.chomp('*')))
      end
    end
  end
end
