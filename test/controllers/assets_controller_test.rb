# frozen_string_literal: true

require_relative '../rails_helper'

# Wiring tests for AssetsController — kept minimal because the controller
# is just three `send_file` calls. Routes-mapping checks catch the most
# likely regression (a typo in config/routes.rb constraint regexes), the
# content-type expectations catch the second-most (wrong MIME on rename).
class AssetsControllerWiringTest < ActiveSupport::TestCase
  def test_turbo_js_route_maps_to_controller
    route = Rails.application.routes.recognize_path('/assets/turbo.js')

    assert_equal 'assets',   route[:controller]
    assert_equal 'turbo_js', route[:action]
  end

  def test_css_route_maps_with_name_extracted
    route = Rails.application.routes.recognize_path('/assets/css/app.css')

    assert_equal 'assets', route[:controller]
    assert_equal 'css',    route[:action]
    assert_equal 'app',    route[:name]
  end

  def test_font_route_maps_with_name_extracted
    route = Rails.application.routes.recognize_path('/assets/vendor/fonts/UcC73FwrK3iLTeHuS_nVMrMxCp50SjIa1ZL7.woff2')

    assert_equal 'assets', route[:controller]
    assert_equal 'font',   route[:action]
    assert_equal 'UcC73FwrK3iLTeHuS_nVMrMxCp50SjIa1ZL7', route[:name]
  end

  def test_css_route_rejects_invalid_name_characters
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path('/assets/css/has spaces.css')
    end
  end

  def test_assets_root_points_at_existing_directory
    assert_path_exists AssetsController::ASSETS_ROOT
    assert_path_exists File.join(AssetsController::ASSETS_ROOT, 'turbo.js')
    assert_path_exists File.join(AssetsController::ASSETS_ROOT, 'css', 'app.css')
  end
end
