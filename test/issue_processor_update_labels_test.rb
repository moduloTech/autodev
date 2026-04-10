# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/danger_claude_runner'
require 'autodev/issue_processor'

# Tests for LabelManager integration with IssueProcessor.
# The deprecated update_labels method has been removed in v0.10.
# Label management is now exclusively handled via LabelManager module
# (apply_label_doing, apply_label_done).
class IssueProcessorLabelManagerTest < Minitest::Test
  # Placeholder — label management is tested via integration tests.
end
