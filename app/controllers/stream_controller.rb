# frozen_string_literal: true

# Server-Sent Events endpoint. One open connection per browser tab.
# Ported off Sinatra's `get '/stream'` — same EventBus contract,
# same `format_sse` framing (Turbo Stream HTML wrapped in
# `data: ...\n\n`), same Cache-Control / X-Accel-Buffering headers
# so reverse proxies do not buffer the response.
#
# Doc §A picked ActionController::Live over ActionCable: "ActionCable
# est overkill pour du one-way LLM streaming". Live mode hands us
# `response.stream` as a writable IO; we loop on the EventBus queue
# until the client disconnects (write raises) or the bus signals
# shutdown via SHUTDOWN_SENTINEL.
class StreamController < ApplicationController
  include ActionController::Live
  include ::Web::Helpers

  # Heartbeat interval (seconds). On every tick we both wake from
  # `queue.pop` and write a `: ping` comment to the stream — if the
  # client has gone away, `response.stream.write` raises and the
  # Puma thread is released. Without this, an idle queue keeps the
  # thread parked indefinitely (Queue#pop does not observe TCP-level
  # disconnects), exhausting Puma's small thread pool over time.
  HEARTBEAT_INTERVAL = 15

  # GET /stream
  def show
    set_sse_headers!
    queue = ::Web::EventBus.subscribe
    pump_events!(queue)
  rescue IOError, ActionController::Live::ClientDisconnected
    # Browser closed the tab — nothing to do.
  ensure
    ::Web::EventBus.unsubscribe(queue) if queue
    response.stream.close
  end

  private

  def set_sse_headers!
    response.headers['Content-Type'] = 'text/event-stream'
    response.headers['Cache-Control'] = 'no-cache'
    response.headers['X-Accel-Buffering'] = 'no'
  end

  def pump_events!(queue)
    loop do
      event = queue.pop(timeout: HEARTBEAT_INTERVAL)
      if event.nil?
        response.stream.write(": ping\n\n")
        next
      end
      break if event == ::Web::EventBus::SHUTDOWN_SENTINEL

      response.stream.write(format_sse(event))
    end
  end
end
