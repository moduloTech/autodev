# frozen_string_literal: true

require_relative '../rails_helper'

class ProjectTicketTemplateTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(gitlab_path: 'g/p', slug: 'g__p')
  end

  def template(**attrs)
    @project.ticket_templates.new(**attrs)
  end

  def test_valid_with_name_and_body
    assert_predicate template(name: 'Évolution', body: '## Contexte'), :valid?
  end

  def test_requires_name_and_body
    refute_predicate template(name: '', body: '## x'), :valid?
    refute_predicate template(name: 'X', body: ''), :valid?
  end

  def test_slug_derived_from_name_when_blank
    t = template(name: 'Bug Report', body: '## x')
    t.valid?

    assert_equal 'bug-report', t.slug
  end

  def test_slug_derivation_strips_accents
    t = template(name: 'Évolution', body: '## x')
    t.valid?

    assert_equal 'evolution', t.slug
  end

  def test_slug_uniqueness_scoped_to_project
    @project.ticket_templates.create!(name: 'Bug', slug: 'bug', body: '## x')

    refute_predicate template(name: 'Autre', slug: 'bug', body: '## y'), :valid?

    other = Project.create!(gitlab_path: 'g/q', slug: 'g__q')

    assert_predicate other.ticket_templates.new(name: 'Bug', slug: 'bug', body: '## x'), :valid?
  end

  def test_slug_format_rejects_invalid
    refute_predicate template(name: 'X', slug: 'Bad Slug', body: '## x'), :valid?
    refute_predicate template(name: 'X', slug: 'UPPER', body: '## x'), :valid?
  end

  def test_default_scope_orders_by_position
    @project.ticket_templates.create!(name: 'B', slug: 'b', body: 'x', position: 2)
    @project.ticket_templates.create!(name: 'A', slug: 'a', body: 'x', position: 1)

    assert_equal %w[a b], @project.ticket_templates.pluck(:slug)
  end

  def test_destroying_project_destroys_templates
    @project.ticket_templates.create!(name: 'Bug', slug: 'bug', body: 'x')

    assert_difference 'ProjectTicketTemplate.count', -1 do
      @project.destroy
    end
  end
end
