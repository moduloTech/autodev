# frozen_string_literal: true

require_relative '../../../rails_helper'

# View-level test for Web::Views::ProjectShow. The controller #show action
# can't render under the rails_helper harness (project_overview_stats pulls
# a legacy Dashboard constant that isn't loaded), so the view is rendered
# directly with explicit inputs — it's a pure function of its kwargs.
class ProjectShowTest < ActiveSupport::TestCase
  def render_show(can_edit: false, tab: 'config', team_owners: [], team_candidates: [], can_manage_owners: false)
    Web::Views::ProjectShow.new(
      project_path: 'group/proj', project_config: {}, project_issues: [],
      stats: Hash.new(0), kpis: Hash.new(0), tab: tab, can_edit: can_edit,
      team_owners: team_owners, team_candidates: team_candidates, can_manage_owners: can_manage_owners
    ).call
  end

  def test_links_to_ticket_templates_for_an_editor
    assert_includes render_show(can_edit: true), '/projects/group__proj/ticket_templates'
  end

  def test_hides_ticket_templates_link_for_a_non_editor
    refute_includes render_show(can_edit: false), '/projects/group__proj/ticket_templates'
  end

  # -- Team tab (Autodev #38) --

  def test_team_tab_lists_current_owners
    owner = User.create!(email: 'owner-one@modulotech.fr', name: 'Owner One')

    assert_includes render_show(tab: 'team', team_owners: [owner]), 'Owner One'
  end

  def test_team_tab_shows_empty_state_when_no_owners
    html = render_show(tab: 'team', team_owners: [])

    assert_includes html, Locales.t(:web_project_owners_none, locale: :fr)
  end

  def test_team_tab_renders_manage_controls_when_can_manage_owners
    owner = User.create!(email: 'owner-two@modulotech.fr', name: 'Owner Two')
    candidate = User.create!(email: 'candidate@modulotech.fr', name: 'Candidate')
    html = render_show(tab: 'team', team_owners: [owner], team_candidates: [candidate], can_manage_owners: true)

    assert_includes html, '/projects/group__proj/owners'
    assert_includes html, "value=\"#{candidate.id}\""
  end

  def test_team_tab_hides_manage_controls_for_a_non_manager
    owner = User.create!(email: 'owner-three@modulotech.fr', name: 'Owner Three')
    html = render_show(tab: 'team', team_owners: [owner], can_manage_owners: false)

    refute_includes html, '/projects/group__proj/owners'
  end
end
