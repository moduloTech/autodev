# frozen_string_literal: true

# Rails' default view helper module. Autodev renders its dashboard with Phlex
# components under `app/components/web/views/`, which carry their own helpers
# (`Web::Helpers`, `Web::I18nHelpers`), so nothing is defined here — the module
# is kept because Rails expects it to exist.
module ApplicationHelper
end
