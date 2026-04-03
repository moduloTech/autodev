# frozen_string_literal: true

class AutodevError < StandardError; end

require_relative 'errors/config_error'
require_relative 'errors/git_error'
require_relative 'errors/implementation_error'
require_relative 'errors/rate_limit_error'
