# frozen_string_literal: true

require_relative '../rails_helper'

class ProjectAppCommandTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(gitlab_path: 'g/p', slug: 'g__p')
  end

  def test_category_must_be_one_of_known_enum
    cmd = ProjectAppCommand.new(project: @project, category: 'deploy', command: %w[bin/deploy])

    refute_predicate cmd, :valid?
    assert_includes cmd.errors[:category], 'is not included in the list'
  end

  def test_command_rejects_empty_or_non_array
    refute_predicate ProjectAppCommand.new(project: @project, category: 'setup', command: []), :valid?
    refute_predicate ProjectAppCommand.new(project: @project, category: 'setup', command: 'bundle install'), :valid?
  end

  def test_command_rejects_array_with_non_string_elements
    refute_predicate ProjectAppCommand.new(project: @project, category: 'setup', command: ['bundle', 42]), :valid?
  end

  def test_command_accepts_non_empty_string_array
    assert_predicate ProjectAppCommand.new(project: @project, category: 'setup', command: %w[bundle install]), :valid?
  end

  def test_command_round_trips_as_json_array
    cmd = ProjectAppCommand.create!(project: @project, category: 'test',
                                    command: %w[bundle exec rake test])

    assert_equal %w[bundle exec rake test], cmd.reload.command
  end

  def test_port_only_allowed_on_run_category
    bad = ProjectAppCommand.new(project: @project, category: 'setup',
                                command: %w[bin/setup], port: 3000)

    refute_predicate bad, :valid?
    assert_includes bad.errors[:port], "is only allowed when category is 'run'"

    good = ProjectAppCommand.new(project: @project, category: 'run',
                                 command: ['bin/rails', 'server'], port: 3000)

    assert_predicate good, :valid?
  end

  def test_run_command_without_port_is_allowed
    # `app.run` YAML entries without `port:` mean "background server not exposed to host".
    cmd = ProjectAppCommand.new(project: @project, category: 'run', command: ['bin/vite', 'dev'])

    assert_predicate cmd, :valid?
  end

  def test_default_ordering_by_category_position
    @project.app_commands.create!(category: 'test', command: %w[bundle exec rspec], position: 0)
    @project.app_commands.create!(category: 'setup', command: %w[yarn install], position: 1)
    @project.app_commands.create!(category: 'setup', command: %w[bundle install], position: 0)

    categories_and_first_word = @project.app_commands.map { |c| [c.category, c.command.first] }

    assert_equal [%w[setup bundle], %w[setup yarn], %w[test bundle]], categories_and_first_word
  end
end
