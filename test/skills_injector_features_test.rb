# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/skills_injector'
require 'tmpdir'

# Tests for SkillsInjector feature detection (test frameworks, sidekiq, devise).
class SkillsInjectorFeaturesTest < Minitest::Test
  def test_detect_rspec
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "gem 'rspec-rails'")
      FileUtils.mkdir_p(File.join(dir, 'spec'))

      assert_equal 'rspec', SkillsInjector.detect_stack(dir)[:test_framework]
    end
  end

  def test_detect_minitest
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "gem 'rails'")
      FileUtils.mkdir_p(File.join(dir, 'test'))

      assert_equal 'minitest', SkillsInjector.detect_stack(dir)[:test_framework]
    end
  end

  def test_detect_both_test_frameworks
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "gem 'rspec-rails'")
      FileUtils.mkdir_p(File.join(dir, 'spec'))
      FileUtils.mkdir_p(File.join(dir, 'test'))

      assert_equal 'both', SkillsInjector.detect_stack(dir)[:test_framework]
    end
  end

  def test_detect_sidekiq_direct
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "gem 'sidekiq'")
      FileUtils.mkdir_p(File.join(dir, 'app', 'workers'))

      stack = SkillsInjector.detect_stack(dir)

      assert stack[:has_sidekiq]
      assert_equal 'direct', stack[:sidekiq_mode]
    end
  end

  def test_detect_sidekiq_activejob
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "gem 'sidekiq'")
      FileUtils.mkdir_p(File.join(dir, 'app', 'jobs'))

      assert_equal 'activejob', SkillsInjector.detect_stack(dir)[:sidekiq_mode]
    end
  end

  def test_detect_sidekiq_both
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "gem 'sidekiq'")
      FileUtils.mkdir_p(File.join(dir, 'app', 'workers'))
      FileUtils.mkdir_p(File.join(dir, 'app', 'jobs'))

      assert_equal 'both', SkillsInjector.detect_stack(dir)[:sidekiq_mode]
    end
  end

  def test_detect_devise
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "gem 'devise'\ngem 'rails'")

      assert SkillsInjector.detect_stack(dir)[:has_devise]
    end
  end

  def test_detect_pundit
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "gem 'pundit'\ngem 'rails'")

      assert SkillsInjector.detect_stack(dir)[:has_pundit]
    end
  end

  def test_detect_rubocop
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "gem 'rubocop'\ngem 'rails'")

      assert SkillsInjector.detect_stack(dir)[:has_rubocop]
    end
  end

  def test_detect_api_only
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "gem 'rails'\napi_only = true")

      assert SkillsInjector.detect_stack(dir)[:api_only]
    end
  end

  def test_no_sidekiq_returns_nil_mode
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "gem 'rails'")

      assert_nil SkillsInjector.detect_stack(dir)[:sidekiq_mode]
    end
  end
end
