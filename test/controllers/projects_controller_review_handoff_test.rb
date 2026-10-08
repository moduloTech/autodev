# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'

# Autodev #90 — the three review-handoff commands are edited from the project
# form like `post_completion`. `#update` writes every `LIST_CONFIG_KEYS` key
# from its param, so a key the form did not render would be erased by the next
# save of any other field: the round trip below is that guard.
class ProjectsControllerReviewHandoffTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  KEYS = %w[review_size_command review_coverage_command reviewer_draw_command].freeze
  COMMANDS = { 'review_size_command' => ['mise', 'x', '--', 'bin/ci/mr_size', '--mr', '%{mr_iid}'], # rubocop:disable Style/FormatStringToken
               'review_coverage_command' => %w[bin/ci/mr_coverage --json],
               'reviewer_draw_command' => %w[bin/ci/reviewer_draw --json] }.freeze

  setup do
    @project = Project.create!(gitlab_path: 'group/proj', slug: 'group__proj', **COMMANDS.transform_keys(&:to_sym))
    @admin = User.create!(email: 'admin@modulotech.fr', name: 'Admin', admin: true)
    sign_in @admin
  end

  test 'the edit form renders each command one element per line' do
    get '/projects/group__proj/edit'

    assert_response :success
    doc = Nokogiri::HTML(response.body)
    KEYS.each do |key|
      field = doc.at_css("textarea[name='#{key}']")

      assert field, "no textarea for #{key}"
      assert_equal COMMANDS[key], field.text.split("\n").map(&:strip).reject(&:empty?)
    end
  end

  test 'submitting the form back keeps the three commands' do
    get '/projects/group__proj/edit'
    doc = Nokogiri::HTML(response.body)
    params = doc.css('textarea, input[type=text], input[type=number]').to_h { |f| [f['name'], f['value'] || f.text] }
    patch '/projects/group__proj', params: params.compact

    @project.reload

    KEYS.each { |key| assert_equal COMMANDS[key], @project.public_send(key) }
  end

  test 'an edited command is persisted' do
    patch '/projects/group__proj', params: { review_size_command: "bin/ci/mr_size\n--json" }

    assert_equal %w[bin/ci/mr_size --json], @project.reload.review_size_command
  end

  test 'emptying the size while coverage stays is refused and nothing is saved' do
    patch '/projects/group__proj', params: { review_size_command: '', review_coverage_command: 'bin/ci/mr_coverage' }

    assert_response :unprocessable_content
    assert_equal COMMANDS['review_size_command'], @project.reload.review_size_command
  end
end
