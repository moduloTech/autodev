# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/skills_injector'
require 'tmpdir'

# Tests for SkillsInjector.inject and skill writing.
class SkillsInjectorInjectTest < Minitest::Test
  def setup
    @logger = StubLogger.new
  end

  def test_inject_creates_four_skills_in_empty_project
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "gem 'rails', '~> 7.0'\ngem 'pg'")
      FileUtils.mkdir_p(File.join(dir, '.claude'))

      result = SkillsInjector.inject(dir, logger: @logger, project_path: 'group/proj')

      assert_equal 4, result[:injected].size
    end
  end

  def test_inject_includes_expected_skill_names
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "gem 'rails', '~> 7.0'\ngem 'pg'")
      FileUtils.mkdir_p(File.join(dir, '.claude'))

      result = SkillsInjector.inject(dir, logger: @logger, project_path: 'group/proj')
      expected = %w[code-conventions rails-conventions test-patterns database-patterns]

      assert_equal expected.sort, result[:injected].sort
    end
  end

  def test_inject_skips_existing_skills
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "gem 'rails'")
      skills_dir = File.join(dir, '.claude', 'skills', 'code-conventions')
      FileUtils.mkdir_p(skills_dir)
      File.write(File.join(skills_dir, 'SKILL.md'), 'custom skill')

      result = SkillsInjector.inject(dir, logger: @logger, project_path: 'group/proj')

      refute_includes result[:injected], 'code-conventions'
      assert_includes result[:existing], 'code-conventions'
    end
  end

  def test_inject_writes_skill_files
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "gem 'rails'")

      SkillsInjector.inject(dir, logger: @logger, project_path: 'group/proj')

      skill_path = File.join(dir, '.claude', 'skills', 'code-conventions', 'SKILL.md')

      assert_path_exists skill_path, 'Expected skill file to be created'
      assert_match(/Code Conventions/, File.read(skill_path, encoding: 'utf-8'))
    end
  end

  def test_inject_returns_stack_info
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "gem 'rails', '~> 7.1'\ngem 'pg'")
      File.write(File.join(dir, '.ruby-version'), '3.2.0')

      result = SkillsInjector.inject(dir, logger: @logger, project_path: 'group/proj')

      assert_equal '3.2.0', result[:stack][:ruby_version]
      assert_equal '7.1', result[:stack][:rails_version]
      assert_includes result[:stack][:databases], 'postgresql'
    end
  end

  def test_skills_instruction_with_skills
    instruction = SkillsInjector.skills_instruction(%w[code-conventions rails-conventions])

    assert_match(/`code-conventions`/, instruction)
    assert_match(/`rails-conventions`/, instruction)
  end

  def test_skills_instruction_empty
    assert_equal '', SkillsInjector.skills_instruction([])
    assert_equal '', SkillsInjector.skills_instruction(nil)
  end

  def test_migrate_legacy_skills_moves_to_subdirectory
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "gem 'rails'")
      skills_dir = File.join(dir, '.claude', 'skills')
      FileUtils.mkdir_p(skills_dir)
      File.write(File.join(skills_dir, 'my-skill.md'), 'legacy content')
      SkillsInjector.inject(dir, logger: @logger, project_path: 'group/proj')

      assert_path_exists File.join(skills_dir, 'my-skill', 'SKILL.md')
      assert_equal 'legacy content', File.read(File.join(skills_dir, 'my-skill', 'SKILL.md'))
    end
  end

  def test_migrate_legacy_skills_appears_in_existing
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "gem 'rails'")
      skills_dir = File.join(dir, '.claude', 'skills')
      FileUtils.mkdir_p(skills_dir)
      File.write(File.join(skills_dir, 'my-skill.md'), 'legacy content')

      result = SkillsInjector.inject(dir, logger: @logger, project_path: 'group/proj')

      assert_includes result[:existing], 'my-skill'
    end
  end

  def test_rails_conventions_includes_version_guidance
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "gem 'rails', '~> 7.1'")

      SkillsInjector.inject(dir, logger: @logger, project_path: 'group/proj')

      skill_path = File.join(dir, '.claude', 'skills', 'rails-conventions', 'SKILL.md')
      content = File.read(skill_path, encoding: 'utf-8')

      assert_match(/Rails 7/, content)
      assert_match(/Hotwire/, content)
    end
  end

  def test_database_skill_includes_postgresql
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "gem 'rails', '~> 7.0'\ngem 'pg'")

      SkillsInjector.inject(dir, logger: @logger, project_path: 'group/proj')

      skill_path = File.join(dir, '.claude', 'skills', 'database-patterns', 'SKILL.md')
      content = File.read(skill_path, encoding: 'utf-8')

      assert_match(/PostgreSQL/, content)
      assert_match(/jsonb/, content)
    end
  end
end
