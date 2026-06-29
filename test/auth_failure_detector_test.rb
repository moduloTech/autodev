# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/auth_failure_detector'

# AuthFailureDetector turns danger-claude's 401 output into a typed
# AuthenticationError so the workers can show a dedicated "no longer connected to
# Claude" message and skip the pointless automatic retry. Observed signature:
#   "Failed to authenticate. API Error: 401 Invalid authentication credentials"
class AuthFailureDetectorTest < Minitest::Test
  def test_401_invalid_credentials_triggers_authentication_error
    assert_raises(AuthenticationError) do
      AuthFailureDetector.check!(
        "Failed to authenticate. API Error: 401 Invalid authentication credentials\n", ''
      )
    end
  end

  def test_signature_in_stderr_triggers
    assert_raises(AuthenticationError) do
      AuthFailureDetector.check!('', 'API Error: 401 Invalid authentication credentials')
    end
  end

  def test_invalid_credentials_phrasing_alone_triggers
    assert_raises(AuthenticationError) do
      AuthFailureDetector.check!('Invalid authentication credentials', '')
    end
  end

  def test_unrelated_failure_does_not_trigger
    AuthFailureDetector.check!("error: command failed\n", 'fatal: ambiguous argument')
    # No raise → pass.
  end

  def test_unrelated_401_in_test_output_only_matches_auth_phrasing
    # A bare "401" without the auth wording must not be misclassified.
    AuthFailureDetector.check!('expected 200 but got 401 from /api/widgets', '')
    # No raise → pass.
  end
end
