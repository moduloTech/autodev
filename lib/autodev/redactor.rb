# frozen_string_literal: true

# Masks secrets before they reach a durable or outward-facing sink.
#
# Autodev embeds the GitLab PAT in clone/fetch/push URLs
# (`https://oauth2:<token>@host/…`). When a git command fails,
# `ShellHelpers.run_cmd` puts the full command into the `GitError` message,
# which then flows into `issues.error_message`, the log files, AND the error
# comment posted on the GitLab issue. `scrub` is applied at those sinks so the
# token never lands anywhere it can be read back (a PAT was found in cleartext
# in months-old log files — see task #10).
module Redactor
  # `://user:pass@` in any URL (covers `oauth2:<token>@`) and a bare
  # `glpat-…` / `gldt-…` GitLab token anywhere else (e.g. an Authorization
  # header echoed in stderr). Tokens are `[A-Za-z0-9._-]+`.
  URL_CREDENTIALS = %r{(://[^:/@\s]+:)[^@\s]+@}
  GITLAB_TOKEN = /\bgl(?:pat|dt|deploy|rt)-[A-Za-z0-9._-]+/

  def self.scrub(text)
    return text unless text.is_a?(String)

    text.gsub(URL_CREDENTIALS, '\1***@').gsub(GITLAB_TOKEN, '***')
  end
end
