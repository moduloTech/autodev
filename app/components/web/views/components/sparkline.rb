# frozen_string_literal: true

module Web
  module Views
    module Components
      # Vertical bar chart used for the "Activité de la semaine" panel.
      # Each bar is topped with its numeric value (the activity count for the
      # day); the rightmost bar is highlighted in the solid accent color (it
      # represents "today" by convention).
      class Sparkline < Phlex::HTML
        # Vertical room reserved at the top of every column for the value label,
        # so a full-height bar plus its number still fit within `height`.
        LABEL_ROOM = 18

        def initialize(values:, height: 72, gap: 8) # rubocop:disable Lint/MissingSuper
          @values = values
          @height = height
          @gap = gap
        end

        def view_template
          max = [@values.max || 0, 1].max
          div(style: container_style) do
            @values.each_with_index { |value, idx| render_column(value, max, idx == @values.length - 1) }
          end
        end

        private

        def container_style
          "display: flex; align-items: flex-end; gap: #{@gap}px; height: #{@height}px;"
        end

        # A column stacks the value label above its bar, both pinned to the
        # bottom so the number floats just above the bar's top edge.
        def render_column(value, max, last)
          div(style: column_style) do
            span(style: label_style(last)) { value.to_s }
            div(style: bar_style(value, max, last))
          end
        end

        def column_style
          'flex: 1; height: 100%; display: flex; flex-direction: column; ' \
            'justify-content: flex-end; align-items: center; gap: 3px;'
        end

        def label_style(last)
          color = last ? 'var(--accent-solid)' : 'var(--text-muted)'
          "font-size: 11px; font-weight: 600; line-height: 1; color: #{color};"
        end

        # Bar height is computed in px against the area left below the label row
        # (height - LABEL_ROOM), so the tallest bar plus its number exactly fill
        # `height`. Non-zero days keep a 4px floor so a small count stays visible;
        # a zero-activity day renders as just its "0" label with no bar.
        def bar_style(value, max, last)
          usable = [@height - LABEL_ROOM, 1].max
          px = (value.to_f / max * usable).round
          px = 4 if value.positive? && px < 4
          color = last ? 'var(--accent-solid)' : 'var(--accent-bg-strong)'
          "width: 100%; height: #{px}px; background: #{color}; border-radius: 4px;"
        end
      end
    end
  end
end
