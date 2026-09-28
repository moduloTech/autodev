# frozen_string_literal: true

# Autodev #125: the excerpt of a backtrace that `error_message` and the log
# carry. The first ten lines alone are not enough when the error is raised deep
# inside a gem — a `Net::OpenTimeout` spends all ten in `net-http`, and the
# frame that says which autodev call was cut never reaches the row. So the head
# is kept as it always was, and followed by the next frames that belong to
# autodev.
#
# "Belongs to autodev" is a path test: under the application root and not
# under its `vendor/`, because the Homebrew install runs from
# `libexec/` with its gems in `libexec/vendor/bundle`.
#
# A plain top-level module, like `GitlabHelpers` — `lib/autodev` is off the
# Zeitwerk autoload path (see lib/autodev.rb's header comment).
module BacktraceExcerpt
  ROOT = File.expand_path('../..', __dir__)
  HEAD = 10
  OWN = 10

  OWN_PREFIX = "#{ROOT}/".freeze
  VENDOR_PREFIX = "#{ROOT}/vendor/".freeze

  module_function

  def own_frame?(line)
    line = line.to_s
    line.start_with?(OWN_PREFIX) && !line.start_with?(VENDOR_PREFIX)
  end

  def lines(error)
    backtrace = error.backtrace
    return [] if backtrace.nil?

    head = backtrace.first(HEAD)
    own = backtrace.drop(HEAD).select { own_frame?(it) }.reject { head.include?(it) }.first(OWN)
    head + own
  end

  def format(error)
    excerpt = lines(error)
    excerpt.empty? ? nil : excerpt.join("\n  ")
  end

  # Judged on the absolute path: `to_s` keeps the path a file was loaded under,
  # which is relative for a script started as `ruby test/…`.
  def first_own_location(locations, skip:)
    location = locations.find do |loc|
      path = loc.absolute_path || File.expand_path(loc.path)
      own_frame?(path) && !skip.include?(path)
    end
    location&.to_s
  end
end
