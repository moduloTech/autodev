# frozen_string_literal: true

require 'phlex'

module Web
  module Views
    # Common base for all Phlex views in the embedded web UI.
    #
    # Includes Web::Helpers so templates have access to t_web, status_class,
    # gitlab_*_url, format_event, etc. The active locale, the current
    # request path, the signed-in user's email, and the per-request CSRF
    # token are passed in by the route (rather than read from a Sinatra-
    # request or controller context) so views stay pure functions of
    # their inputs. Use `**view_kwargs` from any controller that includes
    # `Web::Helpers` to forward the full set in one go.
    class Base < Phlex::HTML
      include Web::Helpers

      def initialize(locale: :fr, request_path: '/', # rubocop:disable Lint/MissingSuper
                     current_user_email: nil, current_user_admin: false, csrf_token: nil)
        @locale = locale
        @request_path = request_path
        @current_user_email = current_user_email
        @current_user_admin = current_user_admin
        @csrf_token = csrf_token
      end

      # Override the I18nHelpers#web_locale that normally walks cookie/config:
      # in a Phlex view we already know the resolved locale.
      def web_locale
        @locale
      end

      # Wrap content with the shared Layout.
      # - `nav: false` skips the top nav (used by views with their own chrome).
      # - `shell: false` skips the centered .page-shell wrapper (used by views
      #   that render a full-width app shell, e.g. dashboard).
      def with_layout(nav: true, shell: true, &)
        render(Layout.new(locale: @locale, request_path: @request_path,
                          nav: nav, shell: shell,
                          current_user_email: @current_user_email,
                          csrf_token: @csrf_token), &)
      end

      # Hidden input every non-GET form must carry under
      # `protect_from_forgery`. Available on any subclass so views can call
      # `csrf_input_tag` from inside hand-written `<form>` blocks.
      def csrf_input_tag
        return if @csrf_token.blank?

        input(type: 'hidden', name: 'authenticity_token', value: @csrf_token)
      end
    end
  end
end
