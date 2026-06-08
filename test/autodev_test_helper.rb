# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/dashboard'
require 'stringio'

# Provide Pastel as FakePastel so Dashboard methods work without the real gem.
unless defined?(Pastel)
  class Pastel < FakePastel
  end
end

# Load methods from bin/autodev without executing gemfile() or main.
autodev_src = File.read(File.expand_path('../bin/autodev', __dir__), encoding: 'utf-8')
stripped = autodev_src
           .sub(/^gemfile.*?^end\n/m, '')
           .gsub(/^require(?:_relative)?\s.*$/, '')
           .gsub(/^I18n\..*$/, '')
           .sub(/^main\s*$/, '')
eval(stripped, TOPLEVEL_BINDING, 'bin/autodev', 1) # rubocop:disable Security/Eval

# Step 2 second half retired the Sequel-side Database module — the parent
# bin/autodev process now boots Rails and uses AR `Issue` directly. The
# stub that used to neuter `Database.connect` / `Database.build_model!` is
# kept as an empty mixin for backwards compatibility with the
# `include StubDatabaseConnect` lines still scattered through legacy
# dashboard tests; it's safe to drop those includes once tests are
# audited.
module StubDatabaseConnect
end
