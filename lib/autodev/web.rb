# frozen_string_literal: true

require 'sinatra/base'
require 'phlex'

require_relative 'web/event_bus'
require_relative 'web/helpers'
require_relative 'web/views/base'
require_relative 'web/views/layout'
require_relative 'web/views/dashboard'
require_relative 'web/views/issue_show'
require_relative 'web/views/errors'
require_relative 'web/views/project_show'
require_relative 'web/views/list'
require_relative 'web/views/issues'
require_relative 'web/server'
