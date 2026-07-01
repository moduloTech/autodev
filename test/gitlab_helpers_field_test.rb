# frozen_string_literal: true

require_relative 'test_helper'
require 'ostruct'
require 'autodev/gitlab_helpers'

# Unit test for the canonical GitlabHelpers.field accessor (Autodev task #17),
# which replaced ~half-a-dozen drifted `x.respond_to?(:f) ? x.f : x['f']` copies.
# It must read from an attribute reader (gitlab gem object), a string-keyed Hash
# (raw JSON), or a symbol-keyed Hash (Ruby-built), and preserve falsey values.
class GitlabHelpersFieldTest < Minitest::Test
  def test_reads_from_an_attribute_reader
    obj = OpenStruct.new(status: 'failed') # rubocop:disable Style/OpenStructUse

    assert_equal 'failed', GitlabHelpers.field(obj, :status)
  end

  def test_reads_from_a_string_keyed_hash
    assert_equal 'failed', GitlabHelpers.field({ 'status' => 'failed' }, :status)
  end

  def test_reads_from_a_symbol_keyed_hash
    assert_equal 'failed', GitlabHelpers.field({ status: 'failed' }, :status)
  end

  def test_prefers_the_string_key_when_both_are_present
    assert_equal 'str', GitlabHelpers.field({ 'status' => 'str', status: 'sym' }, :status)
  end

  def test_preserves_a_false_value_from_a_reader
    obj = OpenStruct.new(allow_failure: false) # rubocop:disable Style/OpenStructUse

    refute GitlabHelpers.field(obj, :allow_failure)
  end

  def test_preserves_a_false_value_from_a_hash
    # A naive `h['k'] || h[:k]` would wrongly skip past a false string-key value.
    refute GitlabHelpers.field({ 'allow_failure' => false }, :allow_failure)
  end

  def test_returns_nil_for_a_missing_hash_key
    assert_nil GitlabHelpers.field({ 'other' => 1 }, :status)
  end

  def test_reader_wins_over_indexing
    # An object that answers both the reader and []: the reader is authoritative.
    dual = Class.new do
      def status = 'reader'
      def [](_key) = 'index'
    end.new

    assert_equal 'reader', GitlabHelpers.field(dual, :status)
  end
end
