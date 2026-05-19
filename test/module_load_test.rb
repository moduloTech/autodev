# frozen_string_literal: true

require_relative 'test_helper'

# Smoke test: every lib/autodev/*.rb file must load without raising at
# require-time. Catches regressions where class-body code (constant
# aliases, method calls, frozen literals) references symbols from
# refactored modules.
#
# Why this matters: bin/autodev requires the whole `autodev` module at
# startup. If any sub-module raises at load, the CLI dies before main
# runs. The pre-existing test_helper only requires a curated subset, so
# such bugs slip through CI — v0.14.0 shipped exactly that flaw.
#
# Modules with gem deps that aren't in the test gemset (Phlex, Sinatra,
# Puma) are skipped via the LoadError rescue. NameError / ScriptError /
# other StandardError are flagged.
class ModuleLoadTest < Minitest::Test
  def test_all_top_level_autodev_modules_load
    files = autodev_module_names
    failures = files.filter_map { |name| try_require(name) }

    refute_empty files, 'Expected to find at least one autodev module'
    assert_empty failures, "Module load failures:\n  #{failures.join("\n  ")}"
  end

  private

  def autodev_module_names
    Dir[File.expand_path('../lib/autodev/*.rb', __dir__)]
      .map { |p| File.basename(p, '.rb') }
      .sort
  end

  def try_require(name)
    require "autodev/#{name}"
    nil
  rescue LoadError
    # External gem missing in test gemset — not a regression in our code.
    nil
  rescue StandardError, ScriptError => e
    "autodev/#{name} raised #{e.class}: #{e.message}"
  end
end
