# frozen_string_literal: true

# Module-level accessor for the Web UI's slice of `~/.autodev/config.yml`.
# Replaces `Web::Server.app_config` (step 8 retired the Sinatra app); the
# legacy_sinatra initializer still loads the config dict on Rails boot
# and calls `Web.config = …` here so Phlex views + helpers can read it.
module Web
  class << self
    attr_accessor :config
  end
end
