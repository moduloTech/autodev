# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/issue_processor'

# Autodev #122, integration review. Each `{` used to rescan to the end of the
# text when nothing closed it: 20 000 unclosed braces took 42 s, 5 000 unclosed
# `{"a":` 8 s â and the text is a model's free answer, so the spec check could
# hang on it. The bound below is generous on purpose: it separates linear from
# quadratic, not a fast machine from a slow one.
class JsonObjectsTest < Minitest::Test
  BOUND = 2.0

  def scan(text) = IssueProcessor::JsonObjects.scan(text)

  def assert_quick_and_empty(text)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = scan(text)
    seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal [], result
    assert_operator seconds, :<, BOUND, "scan took #{seconds.round(2)} s"
  end

  def test_unclosed_braces_are_scanned_in_linear_time
    assert_quick_and_empty('{' * 20_000)
  end

  def test_unclosed_keys_are_scanned_in_linear_time
    assert_quick_and_empty("#{'{"a":' * 5000}x")
  end

  # An object nested in one that never closes is still found: stopping at the
  # first unclosed brace would lose it.
  def test_an_object_inside_an_unclosed_one_is_still_found
    assert_equal [{ 'type' => 'implementation' }], scan('{"verdict": {"type": "implementation"}')
    assert_equal [{}], scan('{{}')
  end

  def test_nested_objects_are_found_in_opening_order
    assert_equal [{ 'a' => { 'b' => 1 } }, { 'b' => 1 }], scan('x {"a": {"b": 1}} y')
  end

  def test_braces_inside_strings_are_not_counted
    assert_equal [{ 'q' => 'a {date} }' }], scan('see {"q": "a {date} }"} end')
  end

  # A French answer: `String#index` counts characters and `StringScanner#pos`
  # bytes, so one accent before the verdict used to shift every start and make
  # the answer unreadable — which proceeds to implementation.
  def test_an_accent_before_the_verdict_does_not_hide_it
    assert_equal [{ 'type' => 'unclear', 'issues' => ['écran'] }],
                 scan(%(Réponse : l'accès. {"type": "unclear", "issues": ["écran"]}))
  end

  def test_a_template_before_the_verdict_does_not_hide_it
    assert_equal [{ 'type' => 'unclear' }], scan('Use {date}. {"type": "unclear"}')
  end
end
