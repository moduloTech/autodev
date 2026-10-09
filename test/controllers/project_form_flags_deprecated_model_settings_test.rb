# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'
require 'nokogiri'

# Autodev #122. `model` and `effort` are deprecated: they still work, and the
# form where a project sets them says so, under each of the two fields and
# under no other.
class ProjectFormFlagsDeprecatedModelSettingsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    Project.create!(gitlab_path: 'group/proj', slug: 'group__proj')
    sign_in User.create!(email: 'admin@modulotech.fr', name: 'Admin', admin: true)
  end

  # The <label> wrapping the field named `key`, by its <code> title.
  def field(body, key)
    Nokogiri::HTML(body).css('label').find { |l| l.at_css('span > code')&.text == key }
  end

  def notice(body, key)
    field(body, key)&.at_css('.deprecated-setting')&.text
  end

  # The notice under `key`, as the fr then the en form renders it.
  def notices(key)
    %w[fr en].map do |locale|
      cookies[:locale] = locale
      get '/projects/group__proj/edit'
      notice(response.body, key).to_s
    end
  end

  def test_the_model_field_carries_the_notice
    get '/projects/group__proj/edit'

    assert_includes notice(response.body, 'model').to_s, 'Déprécié'
  end

  def test_the_effort_field_carries_the_notice
    get '/projects/group__proj/edit'

    assert_includes notice(response.body, 'effort').to_s, 'Déprécié'
  end

  # Integration review of the alpha-57 lot: "with neither, each call takes its
  # agent's model, or else Claude Code's default" was false for the complexity
  # and pipeline evaluations, which pass `model: 'haiku'` and keep it.
  def test_the_model_notice_names_the_haiku_exception_in_both_locales
    fr, en = notices('model')

    assert_equal [true, true], [fr.include?('haiku'), en.include?('haiku')], "fr: #{fr}\nen: #{en}"
  end

  # The same notice sat under `effort` while speaking only of the model.
  def test_the_effort_notice_speaks_of_effort_not_of_the_model
    fr, en = notices('effort')

    assert_equal [true, true, false, false],
                 [fr.include?('effort'), en.include?('effort'), fr.include?('modèle'), en.include?('model')],
                 "fr: #{fr}\nen: #{en}"
  end

  def test_no_other_field_carries_it
    get '/projects/group__proj/edit'
    flagged = Nokogiri::HTML(response.body).css('.deprecated-setting')
                      .map { |n| n.ancestors('label').first.at_css('span > code').text }

    assert_equal %w[model effort], flagged
  end

  # The creation form renders the same fields.
  def test_the_new_project_form_carries_it_too
    get '/projects/new'

    assert_includes notice(response.body, 'model').to_s, 'Déprécié'
  end

  def test_the_notice_follows_the_ui_locale
    cookies[:locale] = 'en'
    get '/projects/group__proj/edit'

    assert_includes notice(response.body, 'model').to_s, 'Deprecated'
  end
end
