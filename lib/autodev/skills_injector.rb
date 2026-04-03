# frozen_string_literal: true

require_relative 'skills_injector/stack_detector'
require_relative 'skills_injector/templates'

# Detects the target project's Ruby/Rails/DB/test stack and injects
# default Claude Code skills into `.claude/skills/` when the repo
# doesn't already provide its own.
#
# Skills are only injected into the temporary clone — the original
# repo is never modified. Existing skills are always preserved.
module SkillsInjector
  SKILL_NAMES = %w[code-conventions rails-conventions test-patterns database-patterns].freeze

  module_function

  # Main entry point. Call after clone + ensure_claude_md, before implement.
  # Returns a hash describing what was detected and injected.
  def inject(work_dir, logger:, project_path:)
    stack = detect_stack(work_dir)
    logger.info("Detected stack: #{stack.inspect}", project: project_path)
    skills_dir = File.join(work_dir, '.claude', 'skills')
    log_migrations(skills_dir, logger, project_path)
    existing = existing_skills(skills_dir)
    log_existing(existing, logger, project_path)
    injected = inject_missing_skills(skills_dir, existing, stack)
    log_injection_result(injected, logger, project_path)
    { stack: stack, existing: existing, injected: injected, all_skills: (existing + injected).uniq.sort }
  end

  # Builds a prompt instruction line listing skills to load.
  def skills_instruction(all_skills)
    return '' if all_skills.nil? || all_skills.empty?

    skill_list = all_skills.map { |s| "`#{s}`" }.join(', ')
    "- Avant de commencer, charge les skills suivants : #{skill_list}."
  end

  # Delegates to StackDetector for backward compatibility with tests.
  def detect_stack(work_dir)
    StackDetector.detect(work_dir)
  end

  # -- Private helpers ---------------------------------------------------------

  def log_existing(existing, logger, project_path)
    return unless existing.any?

    logger.info("Project already has #{existing.size} skill(s): #{existing.join(', ')}", project: project_path)
  end

  def log_migrations(skills_dir, logger, project_path)
    migrated = migrate_legacy_skills(skills_dir)
    return unless migrated.any?

    logger.info("Migrated #{migrated.size} legacy skill(s) to subdirectory format: #{migrated.join(', ')}",
                project: project_path)
  end

  def inject_missing_skills(skills_dir, existing, stack)
    SKILL_NAMES.each_with_object([]) do |name, injected|
      next if existing.include?(name)

      write_skill(skills_dir, name, Templates.send(:"#{name.tr('-', '_')}_skill", stack))
      injected << name
    end
  end

  def log_injection_result(injected, logger, project_path)
    if injected.any?
      logger.info("Injected #{injected.size} skill(s): #{injected.join(', ')}", project: project_path)
    else
      logger.info('No skills injection needed', project: project_path)
    end
  end

  def existing_skills(skills_dir)
    return [] unless Dir.exist?(skills_dir)

    Dir.glob(File.join(skills_dir, '*', 'SKILL.md')).map do |f|
      File.basename(File.dirname(f))
    end
  end

  def migrate_legacy_skills(skills_dir)
    return [] unless Dir.exist?(skills_dir)

    Dir.glob(File.join(skills_dir, '*.md')).filter_map do |legacy_path|
      migrate_single_skill(legacy_path)
    end
  end

  def migrate_single_skill(legacy_path)
    skill_name = File.basename(legacy_path, '.md')
    skill_dir = File.join(File.dirname(legacy_path), skill_name)
    new_path = File.join(skill_dir, 'SKILL.md')
    return nil if File.exist?(new_path)

    FileUtils.mkdir_p(skill_dir)
    FileUtils.mv(legacy_path, new_path)
    skill_name
  end

  def write_skill(skills_dir, skill_name, content)
    skill_dir = File.join(skills_dir, skill_name)
    FileUtils.mkdir_p(skill_dir)
    File.write(File.join(skill_dir, 'SKILL.md'), content)
  end

  private_class_method :log_existing, :log_migrations, :inject_missing_skills, :log_injection_result,
                       :existing_skills, :migrate_legacy_skills, :migrate_single_skill, :write_skill
end
