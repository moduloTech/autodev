# frozen_string_literal: true

require_relative 'test_helper'

# Autodev #130 — what makes two failures of the same job "the same failure".
#
# The name alone does not: on 16/09/2026 `master` failed `test:main` in
# `bundle install` while three merge requests failed `test:main` on real spec
# failures. 36 of the 42 name matches measured in production were a different
# failure. These tests pin the rule the spec derives from those traces.
class FailureSignatureTest < Minitest::Test
  Sig = PipelineMonitor::FailureSignature

  # A GitLab runner trace: timestamp + stream prefix, ANSI colours, CR before the
  # section markers, and the runner's own sections after `step_script`.
  def trace(script_lines, after: ['Uploading artifacts...', 'ERROR: Job failed: exit code 1'])
    lines = ["2026-09-16T14:56:50.000000Z 00O section_start:1:step_script\r\e[0K"]
    lines += script_lines.each_with_index.map { |l, i| "2026-09-16T14:56:5#{i % 10}.123456Z 01O #{l}" }
    lines << "2026-09-16T14:57:00.000000Z 00O section_end:2:step_script\r\e[0K"
    lines += after.map { |l| "2026-09-16T14:57:01.000000Z 01O \e[31;1m#{l}\e[0;m" }
    lines.join("\n")
  end

  def rspec_trace(*examples)
    trace(['Failed examples:', ''] + examples.map { |e| "\e[31mrspec #{e}\e[0m \e[36m# does a thing\e[0m" } +
          ['Took 46 seconds'])
  end

  def test_failed_examples_are_the_signature
    assert_equal [:examples, Set['./spec/a_spec.rb:12', './spec/b_spec.rb:7']],
                 Sig.of(rspec_trace('./spec/a_spec.rb:12', './spec/b_spec.rb:7'))
  end

  def test_minitest_failures_are_examples_too
    sig = Sig.of(trace(['bin/rails test test/models/foo_test.rb:12', 'rails test test/bar_test.rb:3']))

    assert_equal [:examples, Set['test/models/foo_test.rb:12', 'test/bar_test.rb:3']], sig
  end

  def test_a_subset_of_the_target_examples_is_explained
    target = Sig.of(rspec_trace('./spec/a_spec.rb:12', './spec/b_spec.rb:7'))
    mr = Sig.of(rspec_trace('./spec/b_spec.rb:7'))

    assert Sig.explains?(target, mr)
  end

  # The merge request broke one more example than the target: that one is its own.
  def test_one_more_failing_example_is_not_explained
    target = Sig.of(rspec_trace('./spec/a_spec.rb:12'))
    mr = Sig.of(rspec_trace('./spec/a_spec.rb:12', './spec/c_spec.rb:1'))

    refute Sig.explains?(target, mr)
  end

  def test_the_tail_compares_the_last_lines_with_numbers_and_hashes_normalised
    target = Sig.of(trace(['$ bundle install', 'Git error: command failed in /cache/model_mapper-0a1b2c3d4e',
                           'fatal: hardlink different from source at', "'pack-abcdef1234567.idx'"]))
    mr = Sig.of(trace(['$ bundle install', 'Git error: command failed in /cache/model_mapper-9f8e7d6c5b',
                       'fatal: hardlink different from source at', "'pack-1234567abcdef.idx'"]))

    assert_equal :tail, target.first
    assert Sig.explains?(target, mr)
  end

  def test_a_different_last_line_is_not_explained
    target = Sig.of(trace(['$ bundle install', 'fatal: hardlink different from source at']))
    mr = Sig.of(trace(['$ bundle exec rake', 'Tests Failed']))

    refute Sig.explains?(target, mr)
  end

  # Only the last five lines count: what ran long before the failure differs
  # between any two runs and says nothing about it.
  def test_lines_before_the_tail_window_do_not_count
    tail = %w[one two three four five]

    assert Sig.explains?(Sig.of(trace(%w[alpha beta] + tail)), Sig.of(trace(%w[gamma] + tail)))
  end

  # The whole window counts, not only its last line.
  def test_a_different_line_inside_the_window_is_not_explained
    refute Sig.explains?(Sig.of(trace(%w[a b X d e])), Sig.of(trace(%w[a b Y d e])))
  end

  # The runner interleaves Kubernetes scheduling warnings into the job's output.
  def test_runner_scheduling_warnings_are_ignored
    warning = 'WARNING: Event retrieved from the cluster: 0/7 nodes are available: 3 Insufficient memory.'
    target = Sig.of(trace(%w[a b c d e]))
    mr = Sig.of(trace(%w[a b c d e] + [warning]))

    assert Sig.explains?(target, mr)
  end

  # What the runner writes after the script (artifacts, cleanup, its own exit
  # line) is the same for every failure and must not make two differ, nor two
  # different ones look alike.
  def test_only_the_step_script_section_counts
    target = Sig.of(trace(%w[a b c d e], after: ['Uploading artifacts...', 'ERROR: exit code 1']))
    mr = Sig.of(trace(%w[a b c d e], after: ['Cleaning up', 'ERROR: exit code 137']))

    assert Sig.explains?(target, mr)
  end

  def test_a_truncated_trace_has_no_signature
    truncated = "#{rspec_trace('./spec/a_spec.rb:1')}\n\e[33;1mJob's log exceeded limit of 4194304 bytes.\e[0;m"

    assert_nil Sig.of(truncated)
  end

  def test_an_empty_trace_has_no_signature
    assert_nil Sig.of('')
    assert_nil Sig.of(trace([]))
  end

  def test_no_signature_is_never_comparable
    sig = Sig.of(rspec_trace('./spec/a_spec.rb:1'))

    refute Sig.explains?(nil, sig)
    refute Sig.explains?(sig, nil)
    refute Sig.explains?(nil, nil)
  end

  def test_an_examples_signature_and_a_tail_signature_are_never_comparable
    examples = Sig.of(rspec_trace('./spec/a_spec.rb:1'))
    tail = Sig.of(trace(%w[a b c d e]))

    refute Sig.explains?(examples, tail)
    refute Sig.explains?(tail, examples)
  end

  # A trace with no `step_script` marker (an older runner, a job killed before
  # its script ended) is read whole rather than refused.
  def test_a_trace_without_section_markers_is_read_whole
    raw = "Running tests\nfatal: could not read from remote repository"

    assert_equal [:tail, ['Running tests', 'fatal: could not read from remote repository']], Sig.of(raw)
  end
end
