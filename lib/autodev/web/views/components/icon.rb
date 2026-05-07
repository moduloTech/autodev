# frozen_string_literal: true

module Web
  module Views
    module Components
      # Inline SVG icons. Mirrors design_handoff_autodev/primitives.jsx::Icon.
      # Path data is identical to the JSX source. Output goes through
      # raw(safe(...)) because Phlex 2 keeps the HTML and SVG namespaces
      # separate and these are static strings anyway.
      class Icon < Phlex::HTML
        # rubocop:disable Layout/LineLength
        PATHS = {
          'search' => '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
          'filter' => '<path d="M3 5h18M6 12h12M10 19h4"/>',
          'plus' => '<path d="M12 5v14M5 12h14"/>',
          'send' => '<path d="m4 12 16-8-6 18-3-7-7-3z"/>',
          'paperclip' => '<path d="M21 11.5 12 20.5a5.5 5.5 0 0 1-7.78-7.78l9.4-9.4a3.7 3.7 0 0 1 5.23 5.23l-9.4 9.4a1.85 1.85 0 0 1-2.62-2.62l8.34-8.34"/>',
          'image' => '<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="9" cy="9" r="2"/><path d="m21 15-5-5L5 21"/>',
          'check' => '<path d="M5 12.5 10 17 19 7"/>',
          'x' => '<path d="M6 6l12 12M18 6 6 18"/>',
          'alert' => '<path d="M10.3 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><path d="M12 9v4M12 17h.01"/>',
          'info' => '<circle cx="12" cy="12" r="9"/><path d="M12 8v.01M11 12h1v4h1"/>',
          'play' => '<path d="M6 4v16l14-8z"/>',
          'pause' => '<rect x="6" y="4" width="4" height="16"/><rect x="14" y="4" width="4" height="16"/>',
          'refresh' => '<path d="M3 12a9 9 0 0 1 15.5-6.36L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-15.5 6.36L3 16"/><path d="M3 21v-5h5"/>',
          'branch' => '<circle cx="6" cy="6" r="2"/><circle cx="6" cy="18" r="2"/><circle cx="18" cy="6" r="2"/><path d="M6 8v8"/><path d="M18 8v2a4 4 0 0 1-4 4H8"/>',
          'git-mr' => '<circle cx="6" cy="6" r="2"/><circle cx="6" cy="18" r="2"/><circle cx="18" cy="18" r="2"/><path d="M6 8v8"/><path d="M18 16V8a4 4 0 0 0-4-4h-3"/><path d="m13 1-3 3 3 3"/>',
          'external' => '<path d="M14 4h6v6"/><path d="M20 4 10 14"/><path d="M19 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h6"/>',
          'chevron-r' => '<path d="m9 6 6 6-6 6"/>',
          'chevron-l' => '<path d="m15 6-6 6 6 6"/>',
          'chevron-d' => '<path d="m6 9 6 6 6-6"/>',
          'more' => '<circle cx="6" cy="12" r="1.5"/><circle cx="12" cy="12" r="1.5"/><circle cx="18" cy="12" r="1.5"/>',
          'home' => '<path d="M3 11.5 12 4l9 7.5V20a1 1 0 0 1-1 1h-5v-7H9v7H4a1 1 0 0 1-1-1z"/>',
          'list' => '<path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/>',
          'alert-tri' => '<path d="M10.3 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><path d="M12 9v4M12 17h.01"/>',
          'messages' => '<path d="M21 11.5a8.4 8.4 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.4 8.4 0 0 1-3.8-.9L3 21l1.9-5.7a8.4 8.4 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.4 8.4 0 0 1 3.8-.9h.5a8.5 8.5 0 0 1 8 8z"/>',
          'folder' => '<path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/>',
          'settings' => '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/>',
          'arrow-r' => '<path d="M5 12h14M13 5l7 7-7 7"/>',
          'arrow-l' => '<path d="M19 12H5M12 5l-7 7 7 7"/>',
          'sparkles' => '<path d="M12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6l2.1 2.1M16.3 16.3l2.1 2.1M5.6 18.4l2.1-2.1M16.3 7.7l2.1-2.1"/>',
          'code' => '<path d="m16 18 6-6-6-6M8 6l-6 6 6 6"/>',
          'clock' => '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
          'user' => '<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>',
          'users' => '<circle cx="9" cy="8" r="3.5"/><path d="M2 21a7 7 0 0 1 14 0"/><circle cx="17" cy="8" r="3"/><path d="M22 21a6 6 0 0 0-5-5.91"/>',
          'thumb-up' => '<path d="M7 22V11M2 13v7a2 2 0 0 0 2 2h13.5a2 2 0 0 0 1.96-1.6l1.5-7a2 2 0 0 0-1.96-2.4H15V5a3 3 0 0 0-3-3l-3 7v13"/>',
          'thumb-dn' => '<path d="M17 2v11M22 11V4a2 2 0 0 0-2-2H6.5a2 2 0 0 0-1.96 1.6L3 10.6A2 2 0 0 0 5 13h4v4a3 3 0 0 0 3 3l3-7V2"/>',
          'copy' => '<rect x="8" y="8" width="13" height="13" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h10"/>',
          'download' => '<path d="M12 3v12M7 10l5 5 5-5M5 21h14"/>',
          'logout' => '<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9"/>',
          'bell' => '<path d="M18 8a6 6 0 1 0-12 0c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.7 21a2 2 0 0 1-3.4 0"/>',
          'moon' => '<path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/>',
          'sun' => '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.4 1.4M17.6 17.6 19 19M5 19l1.4-1.4M17.6 6.4 19 5"/>',
          'menu' => '<path d="M3 6h18M3 12h18M3 18h18"/>',
          'rocket' => '<path d="M4.5 16.5c-1.5 1.26-2 5-2 5s3.74-.5 5-2c.71-.84.7-2.13-.09-2.91a2.18 2.18 0 0 0-2.91-.09z"/><path d="M12 15l-3-3a22 22 0 0 1 2-3.95 12.88 12.88 0 0 1 9-6c0 3-1 7-6 9a22 22 0 0 1-2 3z"/><path d="M9 12H4s.55-3.03 2-4c1.62-1.08 5 0 5 0"/>'
        }.freeze
        # rubocop:enable Layout/LineLength

        def initialize(name:, size: 16, stroke_width: 1.6, color: 'currentColor') # rubocop:disable Lint/MissingSuper
          @name = name.to_s
          @size = size
          @stroke_width = stroke_width
          @color = color
        end

        def view_template
          inner = PATHS[@name] || ''
          return if inner.empty?

          raw safe(<<~SVG)
            <svg width="#{@size}" height="#{@size}" viewBox="0 0 24 24" fill="none"
                 stroke="#{@color}" stroke-width="#{@stroke_width}"
                 stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">#{inner}</svg>
          SVG
        end
      end
    end
  end
end
