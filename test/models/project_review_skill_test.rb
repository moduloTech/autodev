# frozen_string_literal: true

require_relative '../rails_helper'
require_relative '../database_test_helper'

# `review_skill` names the skill the review step loads from the cloned repo
# (Autodev #74). Optional: absent means the mr-review binary, which is the right
# answer for a project that ships no review skill.
class ProjectReviewSkillTest < ActiveSupport::TestCase
  include DatabaseTestHelper

  def setup = setup_database

  # `slug` isn't auto-derived on the model (ProjectsController#project_identity_params
  # is what computes it from gitlab_path on create), so a bare Project.new needs one
  # set explicitly or `valid?` fails on `slug can't be blank` for reasons unrelated
  # to review_skill.
  def project(**attrs)
    Project.new({ gitlab_path: 'group/app', slug: 'group__app', labels_todo: ['To do'],
                  label_doing: 'Doing', label_done: 'Done' }.merge(attrs))
  end

  def test_a_project_without_a_review_skill_is_valid
    assert_predicate project, :valid?
  end

  def test_a_declared_review_skill_reaches_the_project_config
    config = project(review_skill: 'prepare-mr').to_project_config

    assert_equal 'prepare-mr', config['review_skill']
  end

  def test_an_unset_review_skill_is_absent_from_the_project_config
    refute project.to_project_config.key?('review_skill')
  end

  def test_a_blank_review_skill_is_rejected_rather_than_read_as_unset
    subject = project(review_skill: '')

    refute_predicate subject, :valid?
    assert_includes subject.errors.attribute_names, :review_skill
  end
end
