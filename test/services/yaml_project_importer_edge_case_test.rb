# frozen_string_literal: true

require_relative '../rails_helper'

# Edge-case input tests for YamlProjectImporter. Lives in a separate class
# so the main test class stays under rubocop's class-length limit.
class YamlProjectImporterEdgeCaseTest < ActiveSupport::TestCase
  def test_empty_projects_block_is_a_no_op
    summary = YamlProjectImporter.new(yaml: { 'projects' => [] }).import!

    assert_equal 0, summary.created
    assert_equal 0, Project.count
  end

  def test_nil_yaml_is_treated_as_empty
    summary = YamlProjectImporter.new(yaml: nil).import!

    assert_equal 0, summary.created
  end
end
