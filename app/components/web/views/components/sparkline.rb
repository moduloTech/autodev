# frozen_string_literal: true

module Web
  module Views
    module Components
      # Vertical bar chart used for the "Activité de la semaine" panel.
      # Takes an array of integers; the rightmost bar is highlighted in
      # the solid accent color (it represents "today" by convention).
      class Sparkline < Phlex::HTML
        def initialize(values:, height: 64, gap: 8) # rubocop:disable Lint/MissingSuper
          @values = values
          @height = height
          @gap = gap
        end

        def view_template
          max = [@values.max || 0, 1].max
          div(style: container_style) do
            @values.each_with_index { |value, idx| render_bar(value, max, idx == @values.length - 1) }
          end
        end

        private

        def container_style
          "display: flex; align-items: flex-end; gap: #{@gap}px; height: #{@height}px;"
        end

        def render_bar(value, max, last)
          pct = (value.to_f / max * 100).round
          color = last ? 'var(--accent-solid)' : 'var(--accent-bg-strong)'
          div(style: "flex: 1; height: #{pct}%; background: #{color}; border-radius: 4px; min-height: 6px;")
        end
      end
    end
  end
end
