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

  # Where a project keeps its skills, relative to the repository root.
  SKILLS_DIR = File.join('.claude', 'skills')

  module_function

  # Every repository layout under which a declared skill is available to a
  # danger-claude run, canonical first (Autodev #81, fix round 2).
  #
  # There are two, because `inject` accepts two: `existing_skills` globs
  # `<name>/SKILL.md`, and `migrate_legacy_skills` globs `<name>.md` and moves it
  # into the first shape **before** anything looks. So a repository still on the
  # flat layout reviews perfectly well — the migration happens in the clone.
  #
  # Named here rather than at each reader because the two readers do not look at
  # the same thing. `SkillReviewer#skill_available?` looks at the clone *after*
  # `inject`, where only the canonical shape can remain, and one `File.exist?` is
  # the whole answer. `Autodev::ReviewSkillProbe` looks at the repository over
  # the GitLab API *before* any of that, so it has to ask about both — and the
  # first version of it asked only about the canonical one, which recorded a
  # working project `missing` and put a false accusation of a broken
  # configuration on the health card. One list, so the two cannot drift again;
  # `test/skill_layouts_are_one_definition_test.rb` derives it from the globs
  # below and checks each entry against the real review step.
  def skill_paths(skill)
    [File.join(SKILLS_DIR, skill.to_s, 'SKILL.md'), File.join(SKILLS_DIR, "#{skill}.md")]
  end

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

  # The convention skills are the ones a prompt should load: they describe how to
  # write code in this project. A workflow skill (`mr-review`, `hotfix`,
  # `ship-mep-to-production`) drives a process with its own trigger and its own
  # writes — it is named explicitly by the step that wants it, never broadcast.
  # The review step names its own (Autodev #74).
  PROMPT_SKILL_SUFFIXES = %w[-conventions -patterns].freeze

  # Builds a prompt instruction line listing the convention skills to load.
  def skills_instruction(all_skills)
    relevant = Array(all_skills).select { |s| PROMPT_SKILL_SUFFIXES.any? { |suffix| s.end_with?(suffix) } }
    return '' if relevant.empty?

    "- Avant de commencer, charge les skills suivants : #{relevant.map { |s| "`#{s}`" }.join(', ')}."
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
