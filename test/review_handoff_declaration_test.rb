# frozen_string_literal: true

require_relative 'rails_helper'
require_relative 'database_test_helper'

# Autodev #90 — which scripts measure and draw a delivered merge request is a
# per-project declaration. No project path lives in autodev: a project that
# declares nothing gets nothing written, and one that declares coverage or a
# draw without a size is refused, because the draw is routed on the size and
# nothing is written without one.
class ReviewHandoffDeclarationTest < ActiveSupport::TestCase
  include DatabaseTestHelper

  KEYS = %w[review_size_command review_coverage_command reviewer_draw_command].freeze
  SIZE = ['mise', 'x', '--', 'bin/ci/mr_size', '--mr', '%{mr_iid}', '--json'].freeze # rubocop:disable Style/FormatStringToken

  def setup = setup_database

  def project(**attrs)
    Project.new({ gitlab_path: 'group/app', slug: 'group__app', labels_todo: ['To do'],
                  label_doing: 'Doing', label_done: 'Done' }.merge(attrs))
  end

  test 'the three commands are list config keys, so the form, the cast and the runtime config carry them' do
    KEYS.each { |key| assert_includes Project::LIST_CONFIG_KEYS, key.to_sym }
  end

  test 'a declared command reaches the runtime project config verbatim' do
    config = project(review_size_command: SIZE, reviewer_draw_command: %w[bin/draw]).to_project_config

    assert_equal SIZE, config['review_size_command']
    assert_equal %w[bin/draw], config['reviewer_draw_command']
    refute config.key?('review_coverage_command')
  end

  test 'a project declaring nothing is valid and carries none of the keys' do
    config = project.to_project_config

    assert_predicate project, :valid?
    KEYS.each { |key| refute config.key?(key) }
  end

  test 'a command must be a non-empty array of strings' do
    [[], [1], 'bin/ci/mr_size'].each do |bad|
      subject = project(review_size_command: bad)

      refute_predicate subject, :valid?, "accepted #{bad.inspect}"
      assert_includes subject.errors.attribute_names, :review_size_command
    end
  end

  test 'coverage and the draw are held to the same shape as the size' do
    %i[review_coverage_command reviewer_draw_command].each do |key|
      [[], [1], 'bin/x'].each do |bad|
        subject = project(review_size_command: SIZE, key => bad)

        refute_predicate subject, :valid?, "accepted #{key}: #{bad.inspect}"
        assert_includes subject.errors.attribute_names, key
        assert_raises(ConfigError) do
          ProjectValidator.validate!({ 'review_size_command' => SIZE, key.to_s => bad }, 'p')
        end
      end
    end
  end

  test 'a declared coverage without a size is refused at boot, naming the size' do
    error = assert_raises(ConfigError) { ProjectValidator.validate!({ 'review_coverage_command' => %w[bin/x] }, 'p') }

    assert_includes error.message, 'review_size_command'
  end

  test 'all three survive a save and a reload as arrays' do
    commands = { review_size_command: SIZE, review_coverage_command: %w[bin/cov --json],
                 reviewer_draw_command: %w[bin/draw --json] }
    saved = project(**commands).tap(&:save!).reload

    commands.each { |key, value| assert_equal value, saved.public_send(key) }
  end

  test 'coverage or a draw without a size is refused by the model' do
    %i[review_coverage_command reviewer_draw_command].each do |key|
      subject = project(key => %w[bin/x])

      refute_predicate subject, :valid?, "accepted #{key} without a size"
      assert_includes subject.errors.attribute_names, key
      assert_predicate project(key => %w[bin/x], review_size_command: SIZE), :valid?
    end
  end

  test 'the YAML validator refuses the same shapes at boot' do # rubocop:disable Minitest/MultipleAssertions
    assert_raises(ConfigError) { ProjectValidator.validate!({ 'review_size_command' => [] }, 'p') }
    assert_raises(ConfigError) { ProjectValidator.validate!({ 'review_size_command' => 'bin/x' }, 'p') }
    error = assert_raises(ConfigError) { ProjectValidator.validate!({ 'reviewer_draw_command' => %w[bin/x] }, 'p') }
    assert_includes error.message, 'review_size_command'
    ProjectValidator.validate!({ 'review_size_command' => SIZE, 'reviewer_draw_command' => %w[bin/x] }, 'p')
  end

  test 'every place that enumerates per-project keys enumerates these three' do
    KEYS.each do |key|
      assert_includes Config::DB_BACKED_PROJECT_FIELDS, key
      assert_includes YamlProjectImporter::CONFIG_KEYS, key
    end
  end

  test 'the YAML import carries a declared command into the projects table' do
    yaml = { 'projects' => [{ 'path' => 'group/app', 'labels_todo' => ['To do'], 'label_doing' => 'Doing',
                              'label_done' => 'Done', 'review_size_command' => SIZE }] }
    YamlProjectImporter.new(yaml: yaml).import!

    assert_equal SIZE, Project.find_by(gitlab_path: 'group/app').review_size_command
  end
end
