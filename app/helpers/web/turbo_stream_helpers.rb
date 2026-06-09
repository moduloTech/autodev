# frozen_string_literal: true

module Web
  # Builds Turbo Stream HTML fragments and SSE wire frames from ActivityEvents.
  # Mixed into Web::Helpers so view code can call format_sse / event_row_stream
  # alongside the regular display helpers.
  module TurboStreamHelpers
    # SSE wire format: every line of `data:` must be prefixed; we collapse
    # the stream HTML to a single line to keep things simple.
    def format_sse(event)
      streams = build_turbo_streams(event).map { |s| s.gsub(/\s+/, ' ').strip }.join
      "data: #{streams}\n\n"
    end

    def build_turbo_streams(event)
      streams = [event_row_stream(event)]
      streams << status_badge_stream(event) if event[:kind] == 'transition'
      streams
    end

    def event_row_stream(event)
      target = "events_#{event[:issue_id]}"
      row = <<~HTML
        <tr>
          <td class="muted">#{h(event[:created_at])}</td>
          <td>#{h(event_kind_label(event[:kind]))}</td>
          <td>#{h(event[:level])}</td>
          <td>#{h(format_event(event))}</td>
        </tr>
      HTML
      %(<turbo-stream action="prepend" target="#{target}"><template>#{row}</template></turbo-stream>)
    end

    def status_badge_stream(event)
      target = "status_#{event[:issue_id]}"
      to = event_payload(event)['to'].to_s
      pill_html = status_pill(to).call
      wrapped = %(<span id="#{target}" style="display: inline-flex">#{pill_html}</span>)
      %(<turbo-stream action="replace" target="#{target}"><template>#{wrapped}</template></turbo-stream>)
    end
  end
end
