# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/web'

class WebStatusPillTest < Minitest::Test
  Pill = Web::Views::Components::StatusPill

  def render_pill(status, label, **)
    Pill.new(status: status, label: label, **).call
  end

  def test_renders_label
    html = render_pill('done', 'Terminé')

    assert_includes html, 'Terminé'
  end

  def test_done_uses_ok_tone
    html = render_pill('done', 'Terminé')

    assert_includes html, 'background: var(--ok-bg)'
    assert_includes html, 'color: var(--ok-fg)'
  end

  def test_error_uses_err_tone
    html = render_pill('error', 'X')

    assert_includes html, 'background: var(--err-bg)'
  end

  def test_needs_clarification_uses_warn_tone
    html = render_pill('needs_clarification', 'X')

    assert_includes html, 'background: var(--warn-bg)'
  end

  def test_pending_uses_neutral_tone
    html = render_pill('pending', 'X')

    assert_includes html, 'background: var(--paper-2)'
  end

  def test_working_states_animate_the_dot
    html = render_pill('implementing', 'X')

    assert_includes html, 'pill-dot pill-dot-pulse'
  end

  def test_non_working_states_dot_does_not_pulse
    html = render_pill('done', 'X')

    assert_includes html, 'class="pill-dot"'
    refute_includes html, 'pill-dot-pulse'
  end

  def test_with_dot_false_omits_the_dot
    html = render_pill('done', 'X', with_dot: false)

    refute_includes html, 'pill-dot'
  end

  def test_size_sm_uses_small_padding
    html = render_pill('done', 'X', size: :sm)

    assert_includes html, 'padding: 2px 8px'
  end

  def test_unknown_status_falls_back_to_neutral
    html = render_pill('made_up', 'Mystery')

    assert_includes html, 'background: var(--paper-2)'
    assert_includes html, 'Mystery'
  end

  def test_status_data_covers_every_aasm_state
    # Tripwire: if a new state is added to the AASM model, this test fails
    # so we remember to add a label key + tone.
    aasm_states = %w[
      pending cloning checking_spec implementing committing pushing
      creating_mr reviewing checking_pipeline fixing_discussions
      fixing_pipeline running_post_completion answering_question
      needs_clarification done error
    ]

    assert_equal aasm_states.sort, Pill::STATUS_DATA.keys.sort
  end
end
