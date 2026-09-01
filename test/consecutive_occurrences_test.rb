# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/consecutive_occurrences'

# The counter behind both give-up bounds — `MissingBaseBound` (Autodev #91) and
# `InvalidRequestBound` (Autodev #95) — had no test of its own until the neutral
# review of #95 asked what "%{count} times in a row" actually meant.
#
# It means a run of **occurrences**, and that is the whole of it: `bump` is the
# only writer, a signature that changes restarts the count, and nothing else
# touches it. A cycle in which the fact was not true records nothing, so it
# neither adds to the count nor clears it — which is why the sinks of both bounds
# say "with the same answer" and "for this branch" rather than "in a row", a
# claim about polls that this module never made.
#
# Pinned here rather than left to the two bounds' own files because both of them
# now carry a *sentence* that rests on it, in French and in English, on a client's
# ticket.
class ConsecutiveOccurrencesTest < Minitest::Test
  # The column and nothing else: `bump` reads `stagnation_signatures`, writes it
  # back through `update`, and asks the row for nothing more.
  class FakeIssue
    attr_reader :stagnation_signatures

    def initialize(stagnation_signatures = nil) = @stagnation_signatures = stagnation_signatures

    # `bump` calls `issue.update(stagnation_signatures: …)`; the return value is
    # ignored there, and this one is `nil` rather than the `true` an AR row hands
    # back, so nothing can quietly start depending on it.
    def update(stagnation_signatures:)
      @stagnation_signatures = stagnation_signatures
      nil
    end
  end

  KEY = 'invalid_request'

  def test_a_first_occurrence_counts_one
    assert_equal 1, ConsecutiveOccurrences.bump(FakeIssue.new, KEY, 'mr_note|400|refused')
  end

  def test_the_same_signature_increments
    issue = FakeIssue.new
    counts = Array.new(3) { ConsecutiveOccurrences.bump(issue, KEY, 'mr_note|400|refused') }

    assert_equal [1, 2, 3], counts
  end

  # A different fact is a different count, which is what keeps a bound from
  # summing two unrelated causes into one give-up.
  def test_a_different_signature_restarts_the_count
    issue = FakeIssue.new
    ConsecutiveOccurrences.bump(issue, KEY, 'mr_note|400|refused')
    ConsecutiveOccurrences.bump(issue, KEY, 'mr_note|400|refused')

    assert_equal 1, ConsecutiveOccurrences.bump(issue, KEY, 'mr_note|400|something else')
  end

  # The property both bounds' wording depends on: the run is one of occurrences,
  # so any number of cycles that record nothing leave the count exactly where it
  # was. There is deliberately no way to clear it short of a human re-arm — see
  # the module header for why that is kept rather than fixed.
  def test_recording_nothing_neither_counts_nor_clears
    issue = FakeIssue.new
    ConsecutiveOccurrences.bump(issue, KEY, 'mr_note|400|refused')

    assert_equal 2, ConsecutiveOccurrences.bump(issue, KEY, 'mr_note|400|refused'),
                 'a cycle that recorded nothing moved the count'
    assert_equal %i[bump bumped read], ConsecutiveOccurrences.singleton_methods(false).sort,
                 'a new entry point here can move a count that two client-facing sentences describe — ' \
                 'if you added one, re-read both bounds\' sinks before changing this list'
  end

  # Four writers share the column; a bound may only ever see its own key.
  def test_each_key_counts_on_its_own
    issue = FakeIssue.new
    3.times { ConsecutiveOccurrences.bump(issue, KEY, 'mr_note|400|refused') }

    assert_equal 1, ConsecutiveOccurrences.bump(issue, 'target_branch', 'master')
    assert_equal 4, ConsecutiveOccurrences.bump(issue, KEY, 'mr_note|400|refused')
  end

  # A column this module wrote itself. `{}` means "start the history over", which
  # costs one extra cycle at worst, and no GitLab read sits anywhere underneath —
  # which is why the clause names `JSON::ParserError` and could not be widened
  # without `test/api_failure_is_not_a_verdict_test.rb` demanding a sentence for
  # it (the file joined that scanner's perimeter with this ticket's review).
  def test_an_unreadable_column_starts_the_history_over
    assert_equal 1, ConsecutiveOccurrences.bump(FakeIssue.new('{not json'), KEY, 'mr_note|400|refused')
  end

  # The signature is hashed, so a refusal body of any size costs the column the
  # same, and what the row carries is not GitLab's prose.
  def test_the_stored_signature_is_a_digest_not_the_text
    issue = FakeIssue.new
    ConsecutiveOccurrences.bump(issue, KEY, 'mr_note|400|a very long refusal body')

    refute_includes issue.stagnation_signatures, 'refusal body'
    assert_equal Digest::SHA256.hexdigest('mr_note|400|a very long refusal body'),
                 JSON.parse(issue.stagnation_signatures)[KEY]['signature']
  end
end
