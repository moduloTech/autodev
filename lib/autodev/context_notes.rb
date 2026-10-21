# frozen_string_literal: true

require 'time'

# Which notes of a ticket belong in the prompt context (Autodev #137).
#
# `IssueFormatter.append_comments` used to drop every note carrying autodev's
# signature, its own questions to the requester included, so the context kept
# the answer and lost the question: on POWERPANNE#14746 the spec check read
# « 3. (b) Une interface utilisateur… » without the question that defined (a)
# and (b). Three kinds of autodev note are part of the conversation and are kept
# — the clarification questions, the #121 functional question, and the answer to
# a question ticket. Everything else autodev posts (the activity note, every
# status notice) is machinery and stays out.
#
# A kept note is recognised by its marker first — the three writers append one
# from #137 on, an HTML comment GitLab does not render — and otherwise by its
# first line, matched against the header of its locale key in `fr` and in `en`:
# every note posted before #137 carries no marker. The patterns are derived from
# the locale table rather than restated. A header reworded later keeps the notes
# posted after the change (they are marked) and loses the unmarked ones of the old
# wording: whoever rewords one of these three has to add the old wording as an
# extra pattern here. No such list exists today, because none has been reworded.
#
# `HumanActivity#human_note_after?` deliberately keeps its own rule: it asks
# whether a *person* posted, and an autodev question is not one.
module ContextNotes
  QUESTION_MARKER = '<!-- autodev:question -->'
  ANSWER_MARKER = '<!-- autodev:answer -->'
  MARKERS = [QUESTION_MARKER, ANSWER_MARKER].freeze
  SIGNATURE = '**autodev**'
  KEPT_HEADER_KEYS = %i[spec_unclear_header functional_question_header question_answered_header].freeze
  LOCALES = %i[fr en].freeze
  # `autodev_tag` is `**autodev** (v<VERSION>)`; the version is optional so a
  # tag-less signature still reads as autodev's.
  TAG_PATTERN = '\*\*autodev\*\*(?: \(v[^)\n]*\))?'
  # Captures the placeholder's name, so `split` interleaves it with the literal
  # parts: even indexes are text, odd indexes are names.
  PLACEHOLDER = /%\{(\w+)\}/

  module_function

  def in_context?(note)
    return false if note.system

    body = note.body.to_s
    return true unless body.include?(SIGNATURE)

    MARKERS.any? { |marker| body.include?(marker) } || known_header?(body)
  end

  # GitLab's `issue_notes` answers newest first by default, which put an answer
  # before the question it answers. Ordered here rather than through the
  # request's `sort`, so the order holds whatever the endpoint is asked.
  def chronological(notes)
    notes.sort_by { |note| [Time.parse(note.created_at.to_s), note.id.to_i] }
  end

  def known_header?(body)
    first_line = body.lstrip.lines.first.to_s.strip
    header_patterns.any? { |pattern| pattern.match?(first_line) }
  end

  def header_patterns
    @header_patterns ||= KEPT_HEADER_KEYS.product(LOCALES).filter_map do |key, locale|
      template = Locales.lookup(locale, key)
      header_pattern(template) if template
    end.freeze
  end

  # `%{tag}` is autodev's signature; any other placeholder (`%{mention}`,
  # `%{mr_iid}`, `%{count}`) matches anything on the line. The whole first line
  # has to match, so a header followed by something else is not that header.
  def header_pattern(template)
    source = template.strip.split(PLACEHOLDER, -1).each_with_index.map do |part, index|
      if index.even? then Regexp.escape(part)
      elsif part == 'tag' then TAG_PATTERN
      else '.*?'
      end
    end
    /\A#{source.join}\z/
  end
end
