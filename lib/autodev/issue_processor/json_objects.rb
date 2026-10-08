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
  # when `JSON.parse` accepts it. The scan always resumes one character after
  # the brace it started on, so an object nested inside another — parsed or not
  # (a restated schema `{"type": "implementation" | …}` is not JSON) — is found
  # too, in the order its opening brace appears.
  module JsonObjects
    module_function

    def scan(text)
      text = text.to_s
      objects = []
      pos = 0
      while (start = text.index('{', pos))
        stop = closing_brace(text, start)
        object = stop && parse(text[start..stop])
        objects << object if object
        pos = start + 1
      end
      objects
    end

    # A JSON string (escapes included) as one token, a brace, or a run of
    # anything else; a lone `"` that opens no complete string is plain text.
    TOKEN = /"(?:\\.|[^"\\])*"|[{}]|[^"{}]+|"/m

    # Index of the brace closing the one at `start`, or nil when the text ends
    # first. Braces inside a JSON string are inside one token, so not counted.
    def closing_brace(text, start)
      scanner = StringScanner.new(text)
      scanner.pos = start
      depth = 0
      while (token = scanner.scan(TOKEN))
        depth += { '{' => 1, '}' => -1 }.fetch(token, 0)
        return scanner.pos - 1 if depth.zero?
      end
      nil
    end

    # A candidate starts with `{`, so it parses to a Hash or not at all.
    def parse(candidate)
      JSON.parse(candidate)
    rescue JSON::ParserError
      nil
    end
  end
end
