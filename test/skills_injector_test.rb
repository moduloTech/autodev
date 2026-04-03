# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/skills_injector'
require 'tmpdir'

# Tests for SkillsInjector stack detection (versions and databases).
class SkillsInjectorDetectionTest < Minitest::Test
  def test_detect_ruby_version_from_ruby_version_file
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, '.ruby-version'), "3.2.2\n")
      File.write(File.join(dir, 'Gemfile'), '')

      assert_equal '3.2.2', SkillsInjector.detect_stack(dir)[:ruby_version]
    end
  end

  def test_detect_ruby_version_from_tool_versions
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, '.tool-versions'), "ruby 3.3.0\nnodejs 20.0.0\n")
      File.write(File.join(dir, 'Gemfile'), '')

      assert_equal '3.3.0', SkillsInjector.detect_stack(dir)[:ruby_version]
    end
  end

  def test_detect_ruby_version_from_gemfile
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "ruby '3.1.4'\ngem 'rails'")

      assert_equal '3.1.4', SkillsInjector.detect_stack(dir)[:ruby_version]
    end
  end

  def test_detect_no_ruby_version
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "gem 'rails'")

      assert_nil SkillsInjector.detect_stack(dir)[:ruby_version]
    end
  end

  def test_detect_rails_version_from_lockfile
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "gem 'rails'")
      File.write(File.join(dir, 'Gemfile.lock'), "    rails (7.1.3)\n    railties (7.1.3)")

      assert_equal '7.1.3', SkillsInjector.detect_stack(dir)[:rails_version]
    end
  end

  def test_detect_rails_version_from_gemfile_constraint
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "gem 'rails', '~> 7.0'")

      assert_equal '7.0', SkillsInjector.detect_stack(dir)[:rails_version]
    end
  end

  def test_detect_postgresql
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "gem 'pg'\ngem 'rails'")

      assert_includes SkillsInjector.detect_stack(dir)[:databases], 'postgresql'
    end
  end

  def test_detect_mysql
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "gem 'mysql2'\ngem 'rails'")

      assert_includes SkillsInjector.detect_stack(dir)[:databases], 'mysql'
    end
  end

  def test_detect_sqlite
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "gem 'sqlite3'\ngem 'rails'")

      assert_includes SkillsInjector.detect_stack(dir)[:databases], 'sqlite'
    end
  end

  def test_detect_database_from_database_yml
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "gem 'rails'")
      FileUtils.mkdir_p(File.join(dir, 'config'))
      File.write(File.join(dir, 'config', 'database.yml'), "adapter: postgresql\nhost: localhost")

      assert_includes SkillsInjector.detect_stack(dir)[:databases], 'postgresql'
    end
  end
end
