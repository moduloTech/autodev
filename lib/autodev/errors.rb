# frozen_string_literal: true

class AutodevError < StandardError; end
class ConfigError < AutodevError; end
class GitError < AutodevError; end
class ImplementationError < AutodevError; end
