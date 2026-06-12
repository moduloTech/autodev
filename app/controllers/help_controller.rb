# frozen_string_literal: true

# Serves the in-app help page that renders the functional usage guide
# (`docs/usage/autodev-functional-usage.md`) as HTML. Same content as the
# markdown source the operator edits, just without the pandoc artifacts
# (frontmatter, `\newpage`) — see `HelpDoc` for the stripping logic.
# Images in the guide live under `docs/usage/screenshots/` and are
# served by `#image` rather than going through Propshaft (those files
# are documentation assets, not part of the asset pipeline).
#
# `#image` is the shared image endpoint for both functional and technical
# docs — both reference the same screenshot pool. No admin gate on the
# image endpoint itself: the screenshots are not sensitive and both
# `/help` (open to all signed-in users) and `/admin/help` (admin-gated)
# point at it.
class HelpController < ApplicationController
  include ::Web::Helpers

  # GET /help
  def show
    @html = HelpDoc.render(:functional)
    render html: ::Web::Views::Help.new(
      content: @html, active: 'help',
      title_key: :web_help_title, subtitle_key: :web_help_subtitle,
      **view_kwargs
    ).call.html_safe, layout: false
  end

  # GET /help/images/:filename
  def image
    filename = params[:filename].to_s
    return head :not_found unless filename.match?(HelpDoc::ALLOWED_IMAGE_NAME)

    path = HelpDoc::SCREENSHOT_DIR.join(filename)
    return head :not_found unless File.file?(path)

    response.headers['Cache-Control'] = 'public, max-age=3600'
    send_file path, type: 'image/png', disposition: 'inline'
  end
end
