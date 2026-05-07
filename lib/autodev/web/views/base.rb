# frozen_string_literal: true

require 'phlex'

module Web
  module Views
    # Common base for all Phlex views in the embedded web UI.
    #
    # Includes Web::Helpers so templates have access to t_web, status_class,
    # gitlab_*_url, format_event, etc. The active locale and the current
    # request path are passed in by the route (rather than read from the
    # Sinatra request) so views stay pure functions of their inputs.
    class Base < Phlex::HTML
      include Web::Helpers

      # Phlex::HTML doesn't define #initialize, so super isn't required.
      def initialize(locale: :fr, request_path: '/') # rubocop:disable Lint/MissingSuper
        @locale = locale
        @request_path = request_path
      end

      # Override the I18nHelpers#web_locale that normally walks cookie/config:
      # in a Phlex view we already know the resolved locale.
      def web_locale
        @locale
      end

      # Wrap content with the shared Layout.
      def with_layout(&)
        render(Layout.new(locale: @locale, request_path: @request_path), &)
      end
    end
  end
end
