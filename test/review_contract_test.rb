# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/review_contract'

# The contract the project's review skill writes, and the single rule that
# decides what becomes an inline discussion (Autodev #74): a finding is inline
# when it is BOTH anchorable (carries file + line) AND blocking-class
# (severity error or warning). One rule, so the two conditions cannot be applied
# in the wrong order.
class ReviewContractTest < Minitest::Test
  def contract(findings, verdict: 'changes_requested')
    ReviewContract.parse({ verdict: verdict, summary: 'S', findings: findings }.to_json)
  end

  def test_an_anchorable_blocking_finding_is_inline
    c = contract([{ file: 'a.rb', line: 4, severity: 'error', body: 'B' }])

    assert_equal 1, c.inline.size
    assert_empty c.summary_only
  end

  def test_an_anchorable_nitpick_is_not_inline
    c = contract([{ file: 'a.rb', line: 4, severity: 'nitpick', body: 'B' }])

    assert_empty c.inline
    assert_equal 1, c.summary_only.size
  end

  def test_a_blocking_finding_without_a_line_is_not_inline
    c = contract([{ severity: 'error', body: 'B' }])

    assert_empty c.inline
    assert_equal 1, c.summary_only.size
  end

  def test_a_clean_review_parses_and_yields_nothing_to_post
    c = contract([], verdict: 'approve')

    assert_equal 'approve', c.verdict
    assert_empty c.inline
    assert_empty c.summary_only
  end

  def test_unparseable_json_raises
    assert_raises(ReviewContract::InvalidError) { ReviewContract.parse('not json') }
  end

  def test_a_missing_verdict_raises
    assert_raises(ReviewContract::InvalidError) { ReviewContract.parse({ findings: [] }.to_json) }
  end

  def test_an_unknown_verdict_raises
    assert_raises(ReviewContract::InvalidError) do
      ReviewContract.parse({ verdict: 'lgtm', summary: '', findings: [] }.to_json)
    end
  end

  def test_an_unknown_severity_raises
    assert_raises(ReviewContract::InvalidError) do
      contract([{ file: 'a.rb', line: 1, severity: 'blocker', body: 'B' }])
    end
  end
end
