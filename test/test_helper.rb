# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require 'json'
require 'yaml'
require 'sequel'
require 'aasm'
require 'i18n'

I18n.available_locales = [:en]
I18n.default_locale = :en

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'autodev/errors'
require 'autodev/logger'
require 'autodev/config_validator'
require 'autodev/project_validator'
require 'autodev/config'
require 'autodev/language_detector'
require 'autodev/locales'
require 'autodev/shell_helpers'
require 'autodev/issue_behavior'
require 'autodev/database'

# Minimal Pastel stand-in that returns messages unchanged.
class FakePastel
  %i[red yellow cyan dim green magenta white bold].each do |color|
    define_method(color) { |msg| msg }
  end
end

# Stub logger that captures messages.
class StubLogger
  attr_reader :messages

  def initialize
    @messages = []
  end

  def info(msg, **_opts)
    @messages << msg
  end
end

require_relative 'database_test_helper'
