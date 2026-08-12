# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'

# Autodev #58 — the per-project config form is the path the typo will actually
# arrive through, so each of these pins one way a bad numeric value used to get
# through it in silence.
class ProjectsControllerNumericBoundsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @project = Project.create!(gitlab_path: 'group/proj', slug: 'group__proj')
    @member = User.create!(email: 'member@modulotech.fr', name: 'Member')
    ProjectMembership.create!(user: @member, project: @project, role: 'contributor')
    sign_in @member
  end

  def test_a_value_above_the_declared_ceiling_is_refused
    @project.update!(mr_review_timeout: 3600)
    patch '/projects/group__proj', params: { mr_review_timeout: '86400000' }

    assert_response :unprocessable_entity
    assert_equal 3600, @project.reload.mr_review_timeout
  end

  def test_a_value_below_the_declared_floor_is_refused
    patch '/projects/group__proj', params: { mr_review_timeout: '5' }

    assert_response :unprocessable_entity
    assert_nil @project.reload.mr_review_timeout
  end

  # Before #58 `integer_or_nil` turned an unparseable entry into nil, which the
  # controller writes as "unset" — so a typo silently reverted the setting to
  # the global default and answered with a 302.
  def test_a_non_numeric_entry_is_refused_instead_of_clearing_the_field
    @project.update!(mr_review_timeout: 3600)
    patch '/projects/group__proj', params: { mr_review_timeout: 'trente' }

    assert_response :unprocessable_entity
    assert_equal 3600, @project.reload.mr_review_timeout
  end

  def test_an_empty_entry_still_clears_the_field_to_the_global_default
    @project.update!(mr_review_timeout: 3600)
    patch '/projects/group__proj', params: { mr_review_timeout: '' }

    assert_response :redirect
    assert_nil @project.reload.mr_review_timeout
  end

  def test_the_rejection_is_rendered_in_the_ui_locale_with_the_accepted_range
    patch '/projects/group__proj', params: { mr_review_timeout: '86400000' }

    assert_match(/entier attendu entre 60 et 21600/, response.body)
  end

  def test_the_rejection_does_not_leak_the_activemodel_fallback_message
    patch '/projects/group__proj', params: { mr_review_timeout: '86400000' }

    refute_match(/must be an integer between/, response.body)
  end

  def test_number_inputs_carry_the_declared_bounds
    get '/projects/group__proj/edit'

    assert_match(/name="mr_review_timeout"[^>]*min="60"[^>]*max="21600"/, response.body)
  end

  def test_the_clone_depth_input_keeps_its_zero_floor
    get '/projects/group__proj/edit'

    assert_match(/name="clone_depth"[^>]*min="0"/, response.body)
  end

  def test_the_field_hint_states_the_accepted_range
    get '/projects/group__proj/edit'

    assert_match(/Plage acceptée : 60 à 21600/, response.body)
  end
end
