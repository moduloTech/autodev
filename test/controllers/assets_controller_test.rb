# frozen_string_literal: true

require_relative '../rails_helper'

# Wiring tests for AssetsController. All `/assets/*` URLs now route through
# a single catch-all `show` action that resolves via Propshaft's load_path,
# so the per-pattern tests (one for turbo.js, one for css/:name.css, one
# for fonts) collapse into a path-extraction test + a content-type sanity
# check for each kind we actually serve.
class AssetsControllerWiringTest < ActiveSupport::TestCase
  def test_route_maps_to_controller_with_path_extracted
    route = Rails.application.routes.recognize_path('/assets/css/app.css')

    assert_equal 'assets',  route[:controller]
    assert_equal 'show',    route[:action]
    assert_equal 'css/app.css', route[:path]
  end

  def test_route_extracts_nested_path
    route = Rails.application.routes.recognize_path(
      '/assets/vendor/fonts/UcC73FwrK3iLTeHuS_nVMrMxCp50SjIa1ZL7.woff2'
    )

    assert_equal 'assets', route[:controller]
    assert_equal 'show',   route[:action]
    assert_equal 'vendor/fonts/UcC73FwrK3iLTeHuS_nVMrMxCp50SjIa1ZL7.woff2', route[:path]
  end

  def test_route_handles_digested_filenames
    # Propshaft-style digest in the URL (Mission Control emits these via
    # `stylesheet_link_tag`). The catch-all keeps the digest in `path`;
    # the controller strips it before doing the load_path lookup.
    route = Rails.application.routes.recognize_path(
      '/assets/mission_control/jobs/application-6148a20a.css'
    )

    assert_equal 'assets', route[:controller]
    assert_equal 'show',   route[:action]
    assert_equal 'mission_control/jobs/application-6148a20a.css', route[:path]
  end

  def test_our_static_assets_resolve_through_propshaft_load_path
    %w[css/tokens.css css/app.css css/fonts.css turbo.js].each do |logical|
      asset = Rails.application.assets.load_path.find(logical)

      assert_not_nil asset, "expected Propshaft load_path to include #{logical}"
      assert_path_exists asset.path.to_s
    end
  end
end
