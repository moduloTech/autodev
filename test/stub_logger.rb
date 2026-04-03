# frozen_string_literal: true

# Stub logger that captures messages.
class StubLogger
  attr_reader :messages

  def initialize
    @messages = []
  end

  %i[info warn error debug].each do |level|
    define_method(level) { |msg, **_opts| @messages << msg }
  end
end
