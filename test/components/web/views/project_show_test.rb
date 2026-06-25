# frozen_string_literal: true

require_relative '../../../rails_helper'

# View-level test for Web::Views::ProjectShow. The controller #show action
# can't render under the rails_helper harness (project_overview_stats pulls
# a legacy Dashboard constant that isn't loaded), so the view is rendered
# directly with explicit inputs — it's a pure function of its kwargs.
class ProjectShowTest < ActiveSupport::TestCase
  def render_show(can_edit:)
    Web::Views::ProjectShow.new(
      project_path: 'group/proj', project_config: {}, project_issues: [],
      stats: Hash.new(0), kpis: Hash.new(0), tab: 'config', can_edit: can_edit
    ).call
  end

  def test_links_to_ticket_templates_for_an_editor
    assert_includes render_show(can_edit: true), '/projects/group__proj/ticket_templates'
  end

  def test_hides_ticket_templates_link_for_a_non_editor
    refute_includes render_show(can_edit: false), '/projects/group__proj/ticket_templates'
  end
end
