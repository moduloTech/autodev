# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/verification_contract'

# What the targeted verification pass hands back (Autodev #79), and the one
# property that matters about it: there is no way for a malformed answer to mean
# "addressed". Same reasoning as `ReviewContract` (Autodev #74) — a file rather
# than stdout, and an unreadable file is an unambiguous failure rather than the
# good news.
class VerificationContractTest < Minitest::Test
  def test_an_addressed_verdict_is_read_as_such
    contract = VerificationContract.parse(JSON.generate(verdict: 'addressed', reason: 'guard added'))

    assert_predicate contract, :addressed?
    assert_equal 'guard added', contract.reason
  end

  def test_a_not_addressed_verdict_is_read_as_such
    contract = VerificationContract.parse(JSON.generate(verdict: 'not_addressed', reason: 'wrong file'))

    refute_predicate contract, :addressed?
  end

  def test_an_unknown_verdict_is_refused
    assert_raises(VerificationContract::InvalidError) do
      VerificationContract.parse(JSON.generate(verdict: 'maybe'))
    end
  end

  def test_a_missing_verdict_is_refused
    assert_raises(VerificationContract::InvalidError) { VerificationContract.parse(JSON.generate(reason: 'x')) }
  end

  def test_malformed_json_is_refused
    assert_raises(VerificationContract::InvalidError) { VerificationContract.parse('not json at all') }
  end

  def test_a_json_scalar_is_refused
    assert_raises(VerificationContract::InvalidError) { VerificationContract.parse('"addressed"') }
  end

  # The verdict autodev writes for itself when the pass could not be performed:
  # it exists so that "we could not check" and "the check said no" are the same
  # value to the caller, and neither is "resolve the thread".
  def test_a_rejection_autodev_builds_is_never_addressed
    refute_predicate VerificationContract.rejected('no diff'), :addressed?
  end
end
