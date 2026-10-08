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

  def test_the_model_field_carries_the_notice
    get '/projects/group__proj/edit'

    assert_includes notice(response.body, 'model').to_s, 'Déprécié'
  end

  def test_the_effort_field_carries_the_notice
    get '/projects/group__proj/edit'

    assert_includes notice(response.body, 'effort').to_s, 'Déprécié'
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
