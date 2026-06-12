# frozen_string_literal: true

module Admin
  # Serves the admin-only in-app help page that renders the technical
  # usage guide (`docs/usage/autodev-technical-usage.md`) as HTML.
  # Mirrors `HelpController#show` but inherits the admin gate from
  # `AdminApplicationController`. Shared image endpoint with the
  # functional doc: `HelpController#image` at `/help/images/:filename`.
  class HelpController < AdminApplicationController
    include ::Web::Helpers

    # GET /admin/help
    def show
      @html = ::HelpDoc.render(:technical)
      render html: ::Web::Views::Help.new(
        content: @html, active: 'admin_help',
        title_key: :web_admin_help_title, subtitle_key: :web_admin_help_subtitle,
        **view_kwargs
      ).call.html_safe, layout: false
    end
  end
end
