# frozen_string_literal: true

module Web
  module Views
    module Components
      # Square button with a single icon child. `label` becomes the
      # aria-label. Mirrors primitives.jsx::IconButton.
      class IconButton < Phlex::HTML
        # rubocop:disable Metrics/ParameterLists
        def initialize( # rubocop:disable Lint/MissingSuper
          icon:, label:, size: 30, active: false,
          type: 'button', href: nil, extra_attrs: {}
        )
          @icon = icon
          @label = label
          @size = size
          @active = active
          @type = type
          @href = href
          @extra_attrs = extra_attrs
        end
        # rubocop:enable Metrics/ParameterLists

        def view_template
          if @href
            a(href: @href, class: 'icon-btn', 'aria-label' => @label,
              style: button_style, **@extra_attrs) { render @icon }
          else
            button(type: @type, class: 'icon-btn', 'aria-label' => @label,
                   style: button_style, **@extra_attrs) { render @icon }
          end
        end

        private

        def button_style
          color = @active ? 'var(--accent-fg)' : 'var(--text-muted)'
          background = @active ? 'var(--accent-bg)' : 'transparent'
          "width: #{@size}px; height: #{@size}px; border-radius: 8px; " \
            "color: #{color}; background: #{background}; " \
            'border: 1px solid transparent; ' \
            'display: inline-flex; align-items: center; justify-content: center; cursor: pointer;'
        end
      end
    end
  end
end
