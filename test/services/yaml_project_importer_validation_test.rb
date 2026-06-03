# frozen_string_literal: true

require_relative '../rails_helper'

# Read-only validation tests for YamlProjectImporter. Kept separate from the
# import-write tests to stay under rubocop's class-length limit and to make
# the test purpose obvious from the filename.
class YamlProjectImporterValidationTest < ActiveSupport::TestCase
  def test_rejects_missing_path
    importer = YamlProjectImporter.new(yaml: { 'projects' => [{ 'name' => 'X' }] })
    error = assert_raises(YamlProjectImporter::ValidationError) { importer.validate! }
    assert_match(/'path' is required/, error.message)
  end

  def test_rejects_malformed_path
    importer = YamlProjectImporter.new(yaml: { 'projects' => [{ 'path' => 'no-slash' }] })
    error = assert_raises(YamlProjectImporter::ValidationError) { importer.validate! }
    assert_match(%r{'path' must look like 'group/project'}, error.message)
  end

  def test_rejects_unknown_app_category
    yaml = { 'projects' => [{ 'path' => 'g/p', 'app' => { 'deploy' => [%w[bin/deploy]] } }] }
    error = assert_raises(YamlProjectImporter::ValidationError) { YamlProjectImporter.new(yaml: yaml).validate! }
    assert_match(/unknown category 'deploy'/, error.message)
  end

  def test_rejects_non_string_command_elements
    yaml = { 'projects' => [{ 'path' => 'g/p', 'app' => { 'setup' => [['bundle', 42]] } }] }
    error = assert_raises(YamlProjectImporter::ValidationError) { YamlProjectImporter.new(yaml: yaml).validate! }
    assert_match(/non-empty array of strings/, error.message)
  end

  def test_rejects_run_entry_without_command
    yaml = { 'projects' => [{ 'path' => 'g/p', 'app' => { 'run' => [{ 'port' => 3000 }] } }] }
    error = assert_raises(YamlProjectImporter::ValidationError) { YamlProjectImporter.new(yaml: yaml).validate! }
    assert_match(/'command' must be a non-empty array of strings/, error.message)
  end

  def test_accumulates_multiple_errors_in_one_raise
    yaml = { 'projects' => [{ 'path' => 'no-slash' }, { 'name' => 'X' }] }
    error = assert_raises(YamlProjectImporter::ValidationError) { YamlProjectImporter.new(yaml: yaml).validate! }
    assert_match(%r{projects\[0\]: 'path' must look like 'group/project'}, error.message)
    assert_match(/projects\[1\]: 'path' is required/, error.message)
  end
end
