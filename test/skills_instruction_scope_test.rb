# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/skills_injector'

# The prompt line used to name every skill in the repo — 23 on powerpanne/core,
# including `hotfix` and `resolve-ticket`; 19 on ff/fast/core, including
# `ship-mep-to-production`. Telling Claude to load a ship-to-production skill
# before implementing a ticket is noise at best (Autodev #74).
class SkillsInstructionScopeTest < Minitest::Test
  def test_it_names_the_convention_skills
    line = SkillsInjector.skills_instruction(%w[rails-conventions test-patterns])

    assert_match(/rails-conventions/, line)
    assert_match(/test-patterns/, line)
  end

  def test_it_does_not_name_a_workflow_skill
    line = SkillsInjector.skills_instruction(%w[rails-conventions ship-mep-to-production hotfix mr-review])

    refute_match(/ship-mep-to-production/, line)
    refute_match(/hotfix/, line)
    refute_match(/mr-review/, line)
  end

  def test_no_relevant_skill_yields_no_instruction
    assert_equal '', SkillsInjector.skills_instruction(%w[hotfix])
  end

  def test_it_does_not_name_a_workflow_skill_absent_from_any_denylist
    line = SkillsInjector.skills_instruction(%w[rails-conventions deploy-staging db-migration-runbook])

    refute_match(/deploy-staging/, line)
    refute_match(/db-migration-runbook/, line)
  end

  def test_it_does_not_name_a_skill_with_a_suffix_that_is_not_at_the_end
    line = SkillsInjector.skills_instruction(%w[rails-conventions old-conventions-archive])

    refute_match(/old-conventions-archive/, line)
  end
end
