# frozen_string_literal: true

class AutodevError < StandardError; end

require_relative 'errors/api_unavailable_error'
require_relative 'errors/authentication_error'
require_relative 'errors/config_error'
require_relative 'errors/missing_review_skill_error'
require_relative 'errors/git_error'
require_relative 'errors/implementation_error'
require_relative 'errors/rate_limit_error'
