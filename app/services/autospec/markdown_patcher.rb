# frozen_string_literal: true

module Autospec
  # Applies one of the four `propose_markdown_patch` operations
  # (cf. autodev/docs/autospec.md §G) to a markdown body. Heading matching
  # is case-insensitive + whitespace-trimmed; on miss we fall back to
  # `append_to_end` and the SuggestionApplier surfaces a toast to the CSM
  # ("section non trouvée, ajouté en fin"). Returns the new markdown
  # string; the original input is not mutated.
  class MarkdownPatcher
    OPERATIONS = %w[insert_after_heading replace_section append_to_end create_section].freeze

    Result = Struct.new(:markdown, :fell_back?)

    class UnknownOperation < ArgumentError; end

    def initialize(markdown)
      @markdown = (markdown || '').dup
      @fell_back = false
    end

    def apply(operation:, content:, target_heading: nil)
      raise UnknownOperation, operation.inspect unless OPERATIONS.include?(operation)

      send(operation, target_heading, content.to_s)
      Result.new(markdown: @markdown, fell_back?: @fell_back)
    end

    private

    def append_to_end(_heading, content)
      @markdown = @markdown.strip.empty? ? "#{content.strip}\n" : "#{@markdown.rstrip}\n\n#{content.strip}\n"
    end

    def create_section(heading, content)
      heading_line = heading.to_s.start_with?('#') ? heading.to_s : "## #{heading}"
      block = "#{heading_line}\n\n#{content.strip}"
      append_to_end(nil, block)
    end

    def insert_after_heading(heading, content)
      lines = @markdown.lines
      idx = find_heading_index(lines, heading)
      return fallback_append(content) unless idx

      lines.insert(idx + 1, "\n#{content.strip}\n")
      @markdown = lines.join
    end

    def replace_section(heading, content)
      lines = @markdown.lines
      start_idx = find_heading_index(lines, heading)
      return fallback_append(content) unless start_idx

      end_idx = find_next_heading_at_or_above(lines, start_idx + 1, lines[start_idx])
      replacement = end_idx >= lines.length ? ["\n#{content.strip}\n"] : ["\n#{content.strip}\n\n"]
      lines[(start_idx + 1)...end_idx] = replacement
      @markdown = lines.join
    end

    def fallback_append(content)
      @fell_back = true
      append_to_end(nil, content)
    end

    def find_heading_index(lines, heading)
      target = normalize(heading)
      lines.each_with_index do |line, i|
        next unless line.match?(/\A#+\s/)
        return i if normalize(line.sub(/\A#+\s*/, '')) == target
      end
      nil
    end

    def find_next_heading_at_or_above(lines, from, ref_line)
      ref_level = ref_line.match(/\A(#+)/)[1].length
      (from...lines.length).each do |i|
        m = lines[i].match(/\A(#+)\s/)
        return i if m && m[1].length <= ref_level
      end
      lines.length
    end

    def normalize(value)
      value.to_s.sub(/\A#+\s*/, '').strip.downcase
    end
  end
end
