# frozen_string_literal: true

module SkillsInjector
  # Detects the Ruby/Rails stack from project files (Gemfile, lockfile, etc.).
  module StackDetector
    module_function

    def detect(work_dir)
      gemfile = read_file(work_dir, 'Gemfile')
      lockfile = read_file(work_dir, 'Gemfile.lock')
      database_yml = read_file(work_dir, 'config/database.yml')

      build_stack(work_dir, gemfile, lockfile, database_yml)
    end

    def read_file(work_dir, relative_path)
      path = File.join(work_dir, relative_path)
      File.exist?(path) ? File.read(path) : nil
    end

    def build_stack(work_dir, gemfile, lockfile, database_yml)
      detect_versions(work_dir, gemfile, lockfile, database_yml)
        .merge(detect_features(work_dir, gemfile))
    end

    def detect_versions(work_dir, gemfile, lockfile, database_yml)
      {
        ruby_version: detect_ruby_version(work_dir, gemfile),
        rails_version: detect_rails_version(gemfile, lockfile),
        databases: detect_databases(gemfile, database_yml),
        test_framework: detect_test_framework(work_dir, gemfile)
      }
    end

    def detect_features(work_dir, gemfile)
      detect_gem_flags(gemfile).merge(
        api_only: gemfile&.include?('api_only') || gemfile&.match?(/config\.api_only/),
        sidekiq_mode: detect_sidekiq_mode(work_dir, gemfile)
      )
    end

    def detect_gem_flags(gemfile)
      %i[sidekiq devise pundit cancancan rubocop].to_h do |gem|
        [:"has_#{gem}", gemfile&.include?(gem.to_s) || false]
      end
    end

    def detect_ruby_version(work_dir, gemfile)
      from_ruby_version_file(work_dir) || from_tool_versions(work_dir) || from_gemfile_ruby(gemfile)
    end

    def from_ruby_version_file(work_dir)
      rv = read_file(work_dir, '.ruby-version')&.strip
      rv unless rv.nil? || rv.empty?
    end

    def from_tool_versions(work_dir)
      read_file(work_dir, '.tool-versions')&.match(/^ruby\s+(\S+)/)&.[](1)
    end

    def from_gemfile_ruby(gemfile)
      gemfile&.match(/^\s*ruby\s+["']([^"']+)["']/)&.[](1)
    end

    def detect_rails_version(gemfile, lockfile)
      from_lockfile(lockfile) || from_gemfile_rails(gemfile)
    end

    def from_lockfile(lockfile)
      return nil unless lockfile

      match = lockfile.match(/^\s+rails\s+\((\d+\.\d+(?:\.\d+)?)\)/)
      match ||= lockfile.match(/^\s+railties\s+\((\d+\.\d+(?:\.\d+)?)\)/)
      match&.[](1)
    end

    def from_gemfile_rails(gemfile)
      return nil unless gemfile

      match = gemfile.match(/gem\s+["']rails["']\s*,\s*["']~>\s*(\d+\.\d+(?:\.\d+)?)["']/)
      match ||= gemfile.match(/gem\s+["']rails["']\s*,\s*["'](\d+\.\d+(?:\.\d+)?)["']/)
      match&.[](1)
    end

    DB_GEMFILE_PATTERNS = {
      'postgresql' => /gem\s+["']pg["']/, 'mysql' => /gem\s+["']mysql2["']/, 'sqlite' => /gem\s+["']sqlite3["']/
    }.freeze
    DB_YML_PATTERNS = { 'postgresql' => /postgresql/, 'mysql' => /mysql2?(?:\s|$)/, 'sqlite' => /sqlite/ }.freeze

    def detect_databases(gemfile, database_yml)
      dbs = match_patterns(gemfile, DB_GEMFILE_PATTERNS)
      dbs.empty? ? match_patterns(database_yml, DB_YML_PATTERNS) : dbs
    end

    def match_patterns(content, patterns)
      return [] unless content

      patterns.each_with_object([]) { |(name, re), dbs| dbs << name if content.match?(re) }
    end

    def detect_sidekiq_mode(work_dir, gemfile)
      return nil unless gemfile&.include?('sidekiq')

      has_workers = Dir.exist?(File.join(work_dir, 'app', 'workers'))
      has_jobs = Dir.exist?(File.join(work_dir, 'app', 'jobs'))

      if has_workers && has_jobs then 'both'
      elsif has_workers then 'direct'
      else 'activejob'
      end
    end

    def detect_test_framework(work_dir, gemfile)
      has_rspec = gemfile&.match?(/gem\s+["']rspec/) || Dir.exist?(File.join(work_dir, 'spec'))
      has_minitest = Dir.exist?(File.join(work_dir, 'test'))

      if has_rspec && has_minitest then 'both'
      elsif has_rspec then 'rspec'
      elsif has_minitest then 'minitest'
      else 'unknown'
      end
    end

    private_class_method :build_stack, :detect_versions, :detect_features, :detect_gem_flags,
                         :detect_ruby_version, :from_ruby_version_file,
                         :from_tool_versions, :from_gemfile_ruby,
                         :detect_rails_version, :from_lockfile, :from_gemfile_rails,
                         :detect_databases, :match_patterns, :detect_sidekiq_mode, :detect_test_framework
  end
end
