# frozen_string_literal: true

# Ported off Sinatra's `get '/locale/:lang'`. GET (not PUT) for parity
# with the existing `<a href="/locale/fr">` links sprinkled across the
# Phlex dashboard; CSRF is not relevant since no body is read.
class LocaleController < ApplicationController
  include ::Web::Helpers

  # GET /locale/:lang
  #
  # Sets / clears the `locale` cookie via Web::I18nHelpers#apply_locale_cookie!
  # then redirects to params[:back] (sanitized to a host-relative path
  # by Web::I18nHelpers#safe_back_path).
  def update
    apply_locale_cookie!(params[:lang])
    redirect_to safe_back_path(params[:back])
  end
end
