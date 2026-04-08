# frozen_string_literal: true

require_relative 'test_helper'

class AppInstructionsTest < Minitest::Test
  def test_returns_nil_when_no_app_config
    assert_nil AppInstructions.prompt_section({})
  end

  def test_returns_nil_when_app_is_empty_hash
    assert_nil AppInstructions.prompt_section({ 'app' => {} })
  end

  def test_full_config_includes_header
    result = AppInstructions.prompt_section(full_app_config)

    assert_includes result, '## Environnement applicatif'
  end

  def test_full_config_includes_setup_commands
    result = AppInstructions.prompt_section(full_app_config)

    assert_includes result, '`bundle install`'
    assert_includes result, '`yarn install`'
  end

  def test_full_config_includes_test_and_lint_commands
    result = AppInstructions.prompt_section(full_app_config)

    assert_includes result, '`bin/test`'
    assert_includes result, '`bundle exec rubocop -A`'
  end

  def test_partial_config_only_includes_present_sections
    config = { 'app' => { 'lint' => [%w[rubocop -A]] } }
    result = AppInstructions.prompt_section(config)

    assert_includes result, 'lint'
    refute_includes result, 'setup'
  end

  def test_priority_phrasing_present
    config = { 'app' => { 'setup' => [%w[bundle install]] } }
    result = AppInstructions.prompt_section(config)

    assert_includes result, 'prioritaires sur le CLAUDE.md'
  end

  private

  def full_app_config
    {
      'app' => {
        'setup' => [%w[bundle install], %w[yarn install]],
        'test' => [['bin/test']],
        'lint' => [%w[bundle exec rubocop -A]]
      }
    }
  end
end
