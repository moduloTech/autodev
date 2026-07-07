# frozen_string_literal: true

require_relative '../../../autodev_test_helper'

# The lazy deploy-review `<turbo-frame>`. The `src` + `loading="lazy"`
# attributes must appear ONLY on the frame the issue page embeds (state
# :loading), never on the resolved lazy-fetch *response* (:available /
# :no_job / …). Turbo 8 re-navigates and blanks a response frame that still
# carries `src`/`loading="lazy"`, which made the deploy button flash in and
# then vanish (Autodev #28, second bug: the frame-src re-emission).
class DeployReviewFrameTest < ActiveSupport::TestCase
  def render(state:, action: nil)
    Web::Views::DeployReviewFrame.new(
      issue_id: 42, state: state, action: action, locale: :fr, csrf_token: 'tok'
    ).call
  end

  def test_loading_frame_carries_src_and_lazy_loading
    html = render(state: :loading)

    assert_includes html, 'id="deploy-review-42"'
    assert_includes html, 'src="/issues/42/deploy_review"', 'the page-embedded frame must lazy-load its src'
    assert_includes html, 'loading="lazy"'
  end

  def test_resolved_available_frame_omits_src_and_loading
    html = render(state: :available, action: :retry)

    # The trigger form still posts to the endpoint (that's the action="…"),
    # but the frame itself must not re-declare it as a lazy `src`.
    assert_includes html, 'action="/issues/42/deploy_review"', 'the trigger form still posts to the endpoint'
    refute_includes html, 'src="/issues/42/deploy_review"',
                    'the lazy-fetch response must NOT re-emit src (Turbo would blank the frame)'
    refute_includes html, 'loading="lazy"',
                    'the lazy-fetch response must NOT re-emit loading="lazy"'
  end

  def test_resolved_unavailable_frame_omits_src_and_loading
    html = render(state: :no_job)

    assert_includes html, 'id="deploy-review-42"'
    refute_includes html, 'src="/issues/42/deploy_review"'
    refute_includes html, 'loading="lazy"'
  end
end
