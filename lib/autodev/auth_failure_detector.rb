# frozen_string_literal: true

# Detects Claude API authentication failures in danger-claude output and raises
# AuthenticationError so the error handler can surface a dedicated message and
# skip the automatic retry (retrying an unauthenticated client never helps —
# the credentials have to be fixed first).
module AuthFailureDetector
  # danger-claude surfaces the failure as e.g.
  #   "Failed to authenticate. API Error: 401 Invalid authentication credentials"
  # Match the 401 status, the "invalid authentication credentials" body, and the
  # "failed to authenticate" preamble so any of the variants trips the detector.
  PATTERN = /api error:\s*401\b|invalid authentication credentials|failed to authenticate/i

  module_function

  def check!(stdout, stderr)
    combined = "#{stdout}\n#{stderr}"
    return unless combined.match?(PATTERN)

    raise AuthenticationError, 'danger-claude can no longer authenticate against Claude (API 401)'
  end
end
