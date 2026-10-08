# frozen_string_literal: true

require 'json'
require 'strscan'

class IssueProcessor
  # Every JSON object embedded in a model's free-text answer, in order
  # (Autodev #122).
  #
  # The spec check used to find its verdict with a brace-free regex,
  # `\{[^{}]*"type"…[^{}]*\}`. A question quoting a template (`{date}`) defeated
  # it, and an unreadable answer *proceeds* to implementation — so the request
  # was implemented without the questions it had just produced. The prompt now
  # asks the model to quote what contradicts or is missing, which makes that
  # case likelier. This walks the text instead: a candidate is a balanced
  # `{…}`, counted outside JSON strings (escapes respected), and it is kept only
  # when `JSON.parse` accepts it. Every `{` is a start of its own, so an object
  # nested inside another — parsed or not (a restated schema
  # `{"type": "implementation" | …}` is not JSON), closed or not — is found too,
  # in the order its opening brace appears.
  #
  # Positions are byte offsets throughout, because that is what StringScanner
  # counts: mixed with `String#index`'s characters, one accent before the
  # verdict shifted every start and made a French answer unreadable.
  module JsonObjects
    module_function

    def scan(text)
      text = text.to_s
      closings = Closings.new(text)
      brace_starts(text).filter_map do |start|
        stop = closings.closing_brace(start)
        stop && parse(text.byteslice(start, stop - start + 1))
      end
    end

    def brace_starts(text)
      starts = []
      pos = -1
      starts << pos while (pos = text.byteindex('{', pos + 1))
      starts
    end

    # A candidate starts with `{`, so it parses to a Hash or not at all.
    def parse(candidate)
      JSON.parse(candidate)
    rescue JSON::ParserError
      nil
    end

    # The closing brace of every start, computed in one pass over the text
    # rather than one per start. Rescanning from each `{` to the end of the
    # text cost 42 s on 20 000 unclosed braces (integration review of the
    # alpha-57 lot). Stopping at the first start that never closes is not the
    # answer: `{"v": {"type": …}` holds a verdict inside an object that never
    # closes. What holds is that the tokens read from a position do not depend
    # on where the scan began, so the brace that closes the level a position
    # sits in is the same for every scan reaching it, and is memoised.
    class Closings
      # A JSON string (escapes included) as one token, a brace, or a run of
      # anything else; a lone `"` that opens no complete string is plain text.
      # Braces inside a JSON string are inside one token, so not counted.
      TOKEN = /"(?:\\.|[^"\\])*"|[{}]|[^"{}]+|"/m

      def initialize(text)
        @scanner = StringScanner.new(text)
        @closing = {}
      end

      # Byte offset of the brace closing the one at `start`, or nil when the
      # text ends first.
      def closing_brace(start) = level_end(start + 1)

      private

      # One list per open level, of the positions whose answer is that level's
      # closing brace. The end of the text answers nil for every level still
      # open: an inner level that never closes keeps the outer ones open too.
      def level_end(pos)
        levels = [[]]
        loop do
          stop = @closing.fetch(pos) { read(pos, levels) }
          next pos = stop.first if stop.is_a?(Array)
          return settle(levels.flatten, nil) if stop.nil?

          settle(levels.pop, stop)
          return stop if levels.empty?

          pos = stop + 1
        end
      end

      # The token at an unanswered position: its closing brace when it is
      # one, nil at the end of the text, else `[next position]` — a `{` opens
      # a level the walk descends into.
      def read(pos, levels)
        levels.last << pos
        @scanner.pos = pos
        token = @scanner.scan(TOKEN)
        return nil unless token
        return pos if token == '}'

        levels << [] if token == '{'
        [@scanner.pos]
      end

      def settle(positions, stop)
        positions.each { |position| @closing[position] = stop }
        stop
      end
    end
  end
end
