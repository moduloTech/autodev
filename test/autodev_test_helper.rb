# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/worker_pool'
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

# Mixin that stubs Database.connect/build_model! so in-memory DB survives method calls.
module StubDatabaseConnect
  def setup
    super
    Database.define_singleton_method(:connect) { |_url| true }
    Database.define_singleton_method(:build_model!) { nil }
  end

  def teardown
    Database.singleton_class.remove_method(:connect)
    Database.singleton_class.remove_method(:build_model!)
    super
  end
end
