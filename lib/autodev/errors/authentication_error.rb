# frozen_string_literal: true

# Raised when danger-claude can no longer authenticate against the Claude API
# (e.g. a 401 from an expired/invalid token). Distinct from a transient failure:
# retrying is pointless until the credentials are restored, so the error handler
# does not schedule an automatic retry and the dashboard shows a dedicated message.
class AuthenticationError < AutodevError; end
