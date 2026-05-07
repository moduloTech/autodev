# frozen_string_literal: true

module Web
  module Views
    module Components
      # Surface container with the standard paper background, border, and
      # shadow. `padding` controls inner padding; pass 0 to lay out the
      # children flush (e.g. for a card with its own internal divider).
      class Card < Phlex::HTML
        def initialize(padding: 20, extra_style: nil) # rubocop:disable Lint/MissingSuper
          @padding = padding
          @extra_style = extra_style
        end

        def view_template(&)
          div(class: 'card', style: combined_style, &)
        end

        private

        def combined_style
          base = 'background: var(--paper); border: 1px solid var(--border); ' \
                 'border-radius: var(--r-lg); box-shadow: var(--shadow-xs); ' \
                 "padding: #{@padding.is_a?(Numeric) ? "#{@padding}px" : @padding};"
          @extra_style ? "#{base} #{@extra_style}" : base
        end
      end
    end
  end
end
