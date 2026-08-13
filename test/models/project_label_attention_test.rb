# frozen_string_literal: true

require_relative '../rails_helper'

# `label_attention` — the label a give-up poses instead of `label_done` (Autodev
# #63).
#
# It is a *setting* rather than a derived value because the scope autodev derives
# names a scope, not its values: `label_doing` + `label_done` yield `Development`
# on both configured projects, and what lives in that scope is project taxonomy —
# powerpanne/core has `StandBy`, `Awaiting CR`, `Awaiting Merge` and five
# `ToDo <name>` variants, ff/fast/core only `NeedEstimation`. There is no third
# value autodev could pick without guessing.
#
# So it is optional, and its absence is a defined fallback (no end label at all,
# the row keeps `label_doing`) rather than a missing setting. What it is *not* is
# a standalone setting: nothing poses it on a project with no label workflow.
class ProjectLabelAttentionTest < ActiveSupport::TestCase
  WORKFLOW = { labels_todo: ['todo'], label_doing: 'doing', label_done: 'done' }.freeze

  def project(**attrs)
    Project.new(gitlab_path: 'g/p', slug: 'g__p', **attrs)
  end

  def test_absent_is_valid_and_is_the_documented_fallback
    assert_predicate project(**WORKFLOW), :valid?
  end

  def test_set_alongside_a_complete_workflow_is_valid
    assert_predicate project(**WORKFLOW, label_attention: 'Development::StandBy'), :valid?
  end

  # A blank value would otherwise read as "not configured" and silently take the
  # fallback, so a typo would look like a deliberate choice.
  def test_a_blank_value_is_rejected
    refute_predicate project(**WORKFLOW, label_attention: '  '), :valid?
    refute_predicate project(**WORKFLOW, label_attention: ''), :valid?
  end

  # Optional does not mean standalone: `apply_label_attention` is gated on
  # `label_workflow?`, so this alone configures nothing.
  def test_alone_it_is_an_incomplete_workflow
    p = project(label_attention: 'Development::StandBy')

    refute_predicate p, :valid?
    assert_includes p.errors[:base].join, 'label workflow'
  end

  def test_it_is_emitted_in_to_project_config
    p = project(**WORKFLOW, label_attention: 'Development::StandBy')
    p.save!

    assert_equal 'Development::StandBy', p.to_project_config['label_attention']
  end

  # The runtime reads the per-project config through this hash, so an unset column
  # must leave the key out entirely — that is what makes the fallback a fallback
  # rather than an empty string reaching `apply_label_attention`.
  def test_an_unset_column_emits_no_key
    p = project(**WORKFLOW)
    p.save!

    refute_includes p.to_project_config.keys, 'label_attention'
  end
end
