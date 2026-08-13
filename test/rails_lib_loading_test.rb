# frozen_string_literal: true

require_relative 'rails_helper'

# The Rails-side counterpart of `module_load_test.rb` (Autodev #64).
#
# `module_load_test.rb` asks whether each `lib/autodev` file *can* be required.
# This one asks whether booting the Rails test environment *has* required them,
# which is the question that decides whether a single test file passes on its
# own. `app/` resolves two dozen top-level constants out of `lib/` at runtime
# (`GitlabHelpers`, `Config`, `NumericSettings`, `Locales`, `Redactor`,
# `PipelineMonitor`, `ActivityLogger`, …) and `lib/` is deliberately off the
# Zeitwerk autoload path, so `config/initializers/load_autodev_config.rb` is the
# only thing that defines them.
#
# The failure mode this guards against is the one that made #64: when that
# initializer returned before its `require` under `AUTODEV_SKIP_LEGACY=1`, the
# constants existed in a test process only because some *other* test file had
# already required them. The full suite passed and the file run alone failed —
# invisible in integration, visible exactly when iterating on one file. Nine
# ad-hoc `require`s had accumulated in `test/rails_helper.rb` to paper over it,
# five of them carrying the same explanation.
#
# The expected set is derived from `lib/autodev.rb`'s own require graph rather
# than listed here, so a module added there is covered without touching any
# test — the point of the fix being that the list stops being maintained by hand.
class RailsLibLoadingTest < Minitest::Test
  LIB_ENTRYPOINT = File.expand_path('../lib/autodev.rb', __dir__)

  def test_booting_the_test_environment_defines_the_whole_lib_constant_set
    expected = declared_constants(LIB_ENTRYPOINT)

    assert_operator expected.size, :>, 20, "Expected lib/autodev.rb to declare a constant set, got #{expected.inspect}"

    missing = expected.reject { |name| Object.const_defined?(name) }

    assert_empty missing, "Booting Rails did not define: #{missing.join(', ')}"
  end

  # The `gitlab` gem is part of the same graph — `lib/autodev.rb` requires it,
  # and `config/application.rb` skips `Bundler.require`, so nothing else does.
  # Its absence was the sixth occurrence of the bug (`NameError: uninitialized
  # constant Gitlab` in the AutoSpec importer tests run alone).
  def test_booting_the_test_environment_loads_the_gems_lib_declares
    assert Object.const_defined?(:Gitlab), 'the `gitlab` gem must be loaded'
    assert Object.const_defined?(:Pastel), 'the `pastel` gem must be loaded'
  end

  private

  # Every top-level constant declared by `path` and by everything it pulls in
  # through `require_relative`, as names (strings), deduplicated.
  def declared_constants(path, seen = [])
    return [] unless seen.none?(path)

    seen << path
    source = File.read(path)
    here = source.scan(/^(?:class|module)\s+([A-Z]\w*)/).flatten
    nested = source.scan(/^require_relative\s+['"]([^'"]+)['"]/).flatten.flat_map do |rel|
      declared_constants(File.expand_path("#{rel}.rb", File.dirname(path)), seen)
    end

    (here + nested).uniq
  end
end
