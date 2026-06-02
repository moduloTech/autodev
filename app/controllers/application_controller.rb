# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # Phase A: no controllers actually mounted. ApplicationController exists so
  # that future controllers (phase B) can inherit from it.
  allow_browser versions: :modern
end
