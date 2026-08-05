# frozen_string_literal: true

require_relative 'test_helper'

# The AutoSpec editor must bootstrap on Turbo visits, not only on a cold
# document load.
#
# `autospec.js` is loaded from a <script src> inside the page body
# (Web::Views::AutospecDrafts::Show). Turbo Drive replaces the body on every
# in-app navigation and re-executes body scripts — but `DOMContentLoaded` has
# already fired by then, so an `init` bound to that event alone never runs.
# Reaching a draft by clicking through /autospec_drafts left the whole editor
# unwired (preview tab dead → Autodev #42, dropzone dead → #41, and autosave
# + its localStorage backup dead, which silently dropped edits). A hard reload
# of the same URL worked, which is what made the bug look intermittent.
#
# `turbo:load` also fires on the first page load, so binding both events makes
# `init` run twice — hence the idempotence guard is part of the invariant, not
# an optional extra: double-wiring would upload every dropped file twice.
#
# This asserts on the source text because the suite has no JS runtime. Same
# tactic as DeployReviewFrameTest, which guards the sibling Turbo-semantics
# bug (#28) at the rendered-output level.
class AutospecJsTurboBootstrapTest < ActiveSupport::TestCase
  SOURCE_PATH = File.expand_path('../app/assets/static/js/autospec.js', __dir__)

  def source
    @source ||= File.read(SOURCE_PATH)
  end

  def test_editor_bootstraps_on_turbo_load
    assert_match(/addEventListener\(\s*'turbo:load'\s*,\s*init\s*\)/, source,
                 'autospec.js must wire `init` on turbo:load, or the editor stays dead ' \
                 'after any in-app navigation to a draft (Autodev #41/#42).')
  end

  def test_editor_still_bootstraps_on_a_cold_load
    assert_match(/DOMContentLoaded|readyState/, source,
                 'a cold load (F5, pasted URL) must still bootstrap the editor.')
  end

  def test_init_is_guarded_against_double_wiring
    assert_match(/autospecWired|__autospecEditorWired|data-autospec-wired/, source,
                 'init runs on both turbo:load and the cold-load path, so it must be ' \
                 'idempotent — otherwise every handler is bound twice.')
  end
end
