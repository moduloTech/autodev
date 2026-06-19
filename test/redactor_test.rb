# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/redactor'

# Covers Redactor.scrub — the chokepoint that keeps the GitLab PAT out of
# error messages, logs, and GitLab comments (task #10).
class RedactorTest < Minitest::Test
  def test_masks_credentials_in_a_clone_url
    url = 'https://oauth2:glpat-AbC123_xy.01@source.modulotech.fr/group/proj.git'
    scrubbed = Redactor.scrub(url)

    assert_equal 'https://oauth2:***@source.modulotech.fr/group/proj.git', scrubbed
    refute_includes scrubbed, 'glpat-AbC123_xy.01'
  end

  def test_masks_a_bare_gitlab_token
    assert_equal 'token=*** done', Redactor.scrub('token=glpat-AbC123xyz done')
  end

  def test_masks_token_inside_a_full_git_error_message
    msg = "Command failed: git clone https://oauth2:glpat-SECRETvalue@host/g/p.git /tmp/x\nstdout: \nstderr: boom"
    scrubbed = Redactor.scrub(msg)

    refute_includes scrubbed, 'glpat-SECRETvalue'
    assert_includes scrubbed, 'oauth2:***@host'
  end

  def test_leaves_clean_text_untouched
    clean = 'Command failed: git status\nstderr: nothing to commit'

    assert_equal clean, Redactor.scrub(clean)
  end

  def test_non_string_is_returned_as_is
    assert_nil Redactor.scrub(nil)
    assert_equal 42, Redactor.scrub(42)
  end
end
