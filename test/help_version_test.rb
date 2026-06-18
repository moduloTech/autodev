# frozen_string_literal: true

require_relative 'autodev_test_helper'

# Both in-app help pages (/help functional, /admin/help technical) render the
# shared Web::Views::Help shell, which shows the running Autodev version in
# the topbar.
class HelpVersionTest < Minitest::Test
  def render_help(title_key:, subtitle_key:, active:)
    Web::Views::Help.new(
      content: '<p>doc</p>', active: active,
      title_key: title_key, subtitle_key: subtitle_key,
      locale: :fr, request_path: '/help',
      current_user_email: 't@modulotech.fr', current_user_admin: true, csrf_token: 'x'
    ).call
  end

  def test_functional_help_shows_the_version
    html = render_help(title_key: :web_help_title, subtitle_key: :web_help_subtitle, active: 'help')

    assert_includes html, "Autodev v#{Autodev::VERSION}"
  end

  def test_technical_help_shows_the_version
    html = render_help(title_key: :web_admin_help_title, subtitle_key: :web_admin_help_subtitle,
                       active: 'admin_help')

    assert_includes html, "Autodev v#{Autodev::VERSION}"
  end
end
