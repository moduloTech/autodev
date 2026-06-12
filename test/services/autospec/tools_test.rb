# frozen_string_literal: true

require_relative '../../rails_helper'

module Autospec
  class ToolsTest < ActiveSupport::TestCase
    def test_all_lists_four_tools
      assert_equal 4, Autospec::Tools::ALL.size
    end

    def test_names_match_autospec_g
      expected = %w[propose_markdown_patch propose_full_rewrite propose_title propose_meta_change]

      assert_equal expected, Autospec::Tools::NAMES
    end

    def test_every_tool_has_required_keys
      Autospec::Tools::ALL.each do |tool|
        assert_includes tool.keys, :name,         "tool missing :name (#{tool.inspect})"
        assert_includes tool.keys, :description,  "tool missing :description (#{tool[:name]})"
        assert_includes tool.keys, :input_schema, "tool missing :input_schema (#{tool[:name]})"
      end
    end

    def test_every_tool_requires_summary_in_input_schema
      Autospec::Tools::ALL.each do |tool|
        schema = tool[:input_schema]

        assert_includes schema[:properties].keys, :summary, "#{tool[:name]} missing summary"
        assert_includes schema[:required], 'summary', "#{tool[:name]} summary not required"
      end
    end

    def test_markdown_patch_operations_enum
      op_schema = Autospec::Tools::MARKDOWN_PATCH[:input_schema][:properties][:operation]

      assert_equal %w[insert_after_heading replace_section append_to_end create_section],
                   op_schema[:enum]
    end

    def test_full_rewrite_requires_rationale
      schema = Autospec::Tools::FULL_REWRITE[:input_schema]

      assert_includes schema[:required], 'rationale'
    end

    def test_summary_maxlength_consistent
      Autospec::Tools::ALL.each do |tool|
        summary_schema = tool[:input_schema][:properties][:summary]

        assert_equal Autospec::Tools::SUMMARY_MAX, summary_schema[:maxLength],
                     "#{tool[:name]} summary maxLength mismatch"
      end
    end
  end
end
