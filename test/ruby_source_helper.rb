# frozen_string_literal: true

# "What of this line is code?" — one definition, for the guards that read the
# tree instead of a list.
#
# Two of them needed it and only one had it. `SwallowScanner`
# (`test/api_failure_is_not_a_verdict_test.rb`) got the splitting right and
# documents why the order matters; `test/review_and_probe_read_the_same_thing_test.rb`
# dropped whole comment lines only, so a **trailing** comment stayed in what it
# counted as code — and its "both askers route through the shared module"
# assertion was satisfied by a comment naming the module. An adversarial reader
# demonstrated it: a hand-written copy of what the shared module owns, followed
# by `# ReviewSkillSource`, left all seven tests of that file green.
#
# There are **two** answers here and picking the wrong one weakens the guard that
# picks it, so they are named for what they do rather than both called "the code":
#
#   * `uncommented` cuts the trailing comment and leaves string literals alone.
#     For a guard looking for a *literal* — `config['target_branch']` — because
#     blanking literals is exactly how that offence would hide.
#   * `blanked` also blanks string literals. For a guard looking for a *keyword*
#     — `rescue`, `raise` — because a log message quoting the word is not the
#     keyword, and that false positive has happened here.
#
# Both are deliberately textual, like everything they serve: what these guards
# check is a property of the source a reviewer sees.
module RubySource
  STRING = /"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/
  COMMENT = /#.*/

  module_function

  # The line with its trailing comment cut, literals intact. The comment is
  # located on a copy whose literals are masked **to the same length**, so a `#`
  # inside a literal (`"#{x}"`, `'a # b'`) cannot be read as the start of one and
  # the index still points into the original line.
  #
  # The line ending survives the cut. It has to: the comment runs to the end of
  # the line, so taking it out takes the newline with it, and a caller joining the
  # result back into one String would find the next line glued onto this one —
  # which silently defeats every `^`-anchored pattern a guard applies to the
  # result. Found that way, by a guard that then matched nothing.
  def uncommented(line)
    hash = masked(line).index('#')
    return line unless hash

    "#{line[0...hash].rstrip}\n"
  end

  # The line with literals blanked and the trailing comment cut. Strings go
  # first, so removing the comment cannot cut a `#` out of the middle of a
  # literal. Both blind spots this handles are the same mistake in two
  # directions: a log message containing the word "raise" made a rescue clause
  # look like a re-raise, and the same text could equally invent a `rescue` where
  # the code has none.
  def blanked(line) = line.gsub(STRING, '""').sub(COMMENT, '')

  # A whole file, comments cut, literals intact.
  def uncommented_file(path) = File.readlines(path).map { |line| uncommented(line) }.join

  # Literals replaced by `x`s of the same width, so offsets are preserved.
  def masked(line)
    line.gsub(STRING) { |literal| "#{literal[0]}#{'x' * (literal.length - 2)}#{literal[-1]}" }
  end
end
