# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/skills_injector'
require 'autodev/pipeline_monitor'
require 'tmpdir'

# "Is this declared skill available?" must have exactly one answer, and both
# askers must ask it (Autodev #81, fix round 2).
#
# There are two askers and they look at different things. `SkillReviewer` looks
# at the **clone, after `SkillsInjector.inject` has run**, so by then a flat
# `.claude/skills/<name>.md` has already been moved to `<name>/SKILL.md` and one
# `File.exist?` is the whole answer. `ReviewSkillProbe` looks at the
# **repository, before any of that**, over the GitLab API, so it has to know
# every layout the migration accepts — and the first version of it did not,
# which made it record a working project `missing` and put a false accusation of
# a broken configuration on the health card.
#
# So the layouts are named once, by the module that owns both of them
# (`SkillsInjector` runs the migration and writes the injected skills), and this
# file pins that list from two directions:
#
#   * **derived**: the list is compared against the globs `SkillsInjector`
#     itself uses. A layout added to the module without being added to the list
#     fails here rather than becoming a false accusation in production;
#   * **behavioural**: every listed layout is materialised in a scratch repo,
#     run through the real `inject`, and handed to the real
#     `SkillReviewer#skill_available?`. That is what makes the list *true* and
#     not merely spelled the same.
#
# The limit, stated rather than left implicit: this proves every declared layout
# is real and that the module declares no glob the list omits. It cannot prove
# that no *future* code path makes a skill available by some other means than a
# glob over `.claude/skills`.
class SkillLayoutsAreOneDefinitionTest < Minitest::Test
  SKILL = 'prepare-mr'
  INJECTOR_SOURCE = File.expand_path('../lib/autodev/skills_injector.rb', __dir__)

  # `Dir.glob(File.join(skills_dir, <parts>))` — the only way the module decides
  # a skill is there. Two call sites today: `existing_skills` (`*/SKILL.md`) and
  # `migrate_legacy_skills` (`*.md`).
  GLOB_CALL = /Dir\.glob\(File\.join\(skills_dir, ([^)]+)\)\)/

  class StubLogger
    def info(*, **) = nil
    def warn(*, **) = nil
    def error(*, **) = nil
    def debug(*, **) = nil
  end

  def test_the_declared_layouts_are_the_ones_the_injector_globs_for
    assert_equal globbed_layouts.sort, SkillsInjector.skill_paths(SKILL).sort, <<~MSG
      `SkillsInjector.skill_paths` and the globs `SkillsInjector` actually uses have
      diverged. Every glob over `.claude/skills` is a layout under which a declared
      review skill is available in the clone, so it is also a layout
      `ReviewSkillProbe` has to ask GitLab about — otherwise a project using it is
      recorded `missing` and the health card accuses a configuration that works.
    MSG
  end

  def test_at_least_two_layouts_are_covered
    assert_operator globbed_layouts.size, :>=, 2,
                    "the glob scan of #{INJECTOR_SOURCE} found #{globbed_layouts.size} layout(s) — " \
                    'the scan has stopped matching the source'
  end

  # The half that makes the list true rather than merely consistent: each
  # declared layout, materialised alone, must satisfy the real review step.
  def test_every_declared_layout_survives_injection_and_satisfies_the_review_step
    SkillsInjector.skill_paths(SKILL).each do |layout|
      assert available_after_inject?(layout),
             "a repository carrying only `#{layout}` is declared available, but " \
             '`SkillReviewer#skill_available?` does not find the skill after injection'
    end
  end

  # The counter-example, so the list is not trivially satisfiable: a file under
  # the skill's directory that is not `SKILL.md` is not a layout, and the probe
  # must not treat it as one.
  def test_an_undeclared_shape_is_not_available
    refute available_after_inject?(File.join('.claude', 'skills', SKILL, 'README.md'))
  end

  private

  # The layouts the module's own globs accept, expressed as repository paths for
  # `SKILL`: `*` is the skill name, and the glob is rooted at `.claude/skills`.
  def globbed_layouts
    @globbed_layouts ||= File.read(INJECTOR_SOURCE).scan(GLOB_CALL).map do |(parts)|
      segments = parts.scan(/'([^']+)'/).flatten
      File.join('.claude', 'skills', *segments).sub('*', SKILL)
    end
  end

  # Materialise a repository holding exactly `layout`, run the real injection,
  # then ask the real review step.
  def available_after_inject?(layout)
    Dir.mktmpdir do |dir|
      path = File.join(dir, layout)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "# #{SKILL}")
      SkillsInjector.inject(dir, logger: StubLogger.new, project_path: 'group/project')
      PipelineMonitor.allocate.send(:skill_available?, dir, SKILL)
    end
  end
end
