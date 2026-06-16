# frozen_string_literal: true

module Autospec
  # Orchestrates one chat turn against the Anthropic Messages API on
  # behalf of an AutospecDraft. See autodev/docs/autospec.md §A (Modèle
  # Claude) and §G (tool protocol + caching) for the underlying design.
  #
  # Flow:
  #   1. Persist the CSM's user message.
  #   2. Build the API request from the full chat history (synthesises
  #      tool_results from prior `applied_at` stamps — see
  #      MessageBuilder).
  #   3. Send to Anthropic. The default client is lazy-loaded from the
  #      `anthropic` gem; tests inject a stub via the `client:` kwarg so
  #      the gem (and the real network) never touch the test boot.
  #   4. Persist the assistant response, separating text from tool_use
  #      blocks so AutospecMessage.tool_calls holds only the suggestions.
  #   5. Return the new assistant message.
  #
  # Streaming is intentionally NOT plumbed here — step 9c will wire the
  # controller + decide between `Anthropic::Resources::Messages#stream`
  # and ActionCable + Solid Cable per autospec.md §L. Until then,
  # `reply` is a blocking call.
  class Chat
    DEFAULT_MODEL = 'claude-sonnet-4-6'
    DEFAULT_MAX_TOKENS = 4096

    class ConfigError < StandardError
    end

    class << self
      # Test injection seam: when set, every Chat instance built without
      # an explicit `client:` uses this client instead of building the
      # real Anthropic SDK one. Controller tests set this in `setup` and
      # restore to nil in `teardown`. The Chat service tests pass `client:`
      # directly via the constructor and ignore this hook.
      attr_accessor :default_client

      # True when a chat turn could plausibly succeed: a test stub is
      # installed, OR an env var carries the key, OR `~/.autodev/config.yml`
      # carries one under `anthropic.api_key`. Used by the controller to
      # short-circuit `#chat` with 503 instead of 500'ing inside the
      # service, and by the view layer to grey out the composer + show
      # an admin banner on the dashboard.
      def api_key_configured?
        return true if default_client

        resolved_api_key.present?
      end

      # Returns the configured key (string) or nil. Folded here so both
      # the predicate above and the instance-side `#api_key` use one
      # lookup. `Web.config` may not be loaded at boot (e.g. rake tasks
      # running before the initializer fires); the guard keeps the call
      # safe in that path.
      def resolved_api_key
        ENV['ANTHROPIC_API_KEY'].presence || web_config_api_key
      end

      private

      def web_config_api_key
        return nil unless defined?(::Web) && ::Web.respond_to?(:config) && ::Web.config

        ::Web.config.dig('anthropic', 'api_key').presence
      end
    end

    attr_reader :draft

    def initialize(draft, client: nil, model: DEFAULT_MODEL, max_tokens: DEFAULT_MAX_TOKENS)
      @draft      = draft
      @client     = client || self.class.default_client
      @model      = model
      @max_tokens = max_tokens
    end

    # Persists the user message, dispatches the request, persists the
    # response. Returns the new assistant AutospecMessage. The user
    # message is created in its own transaction so a network failure on
    # the API call doesn't roll back the CSM's input — they get to see
    # what they typed and retry without re-typing.
    def reply(user_content:)
      AutospecMessage.create!(autospec_draft: draft,
                              role: AutospecMessage::ROLE_USER,
                              content: user_content)

      response = client.messages.create(request_params)

      persist_response!(response)
    end

    def client
      @client ||= build_default_client
    end

    private

    def request_params
      {
        model: @model,
        max_tokens: @max_tokens,
        system: SystemPrompt.build(draft),
        messages: MessageBuilder.build(draft),
        tools: Tools::ALL
      }
    end

    def persist_response!(response)
      blocks = Array(response.content)
      text  = blocks.select { |b| block_type(b) == 'text' }.map { |b| block_text(b) }.join("\n\n")
      tools = blocks.select { |b| block_type(b) == 'tool_use' }.map { |b| serialise_tool_use(b) }

      AutospecMessage.create!(autospec_draft: draft,
                              role: AutospecMessage::ROLE_ASSISTANT,
                              content: text.presence,
                              tool_calls: tools)
    end

    # The SDK returns BaseModel objects with attribute readers; tests pass
    # plain OpenStructs / hashes. These two helpers normalise across both.
    def block_type(block)
      block.respond_to?(:type) ? block.type.to_s : block['type'].to_s
    end

    def block_text(block)
      block.respond_to?(:text) ? block.text : block['text']
    end

    def serialise_tool_use(block)
      {
        'type' => 'tool_use',
        'id' => attr(block, :id),
        'name' => attr(block, :name),
        'input' => stringify_keys(attr(block, :input))
      }
    end

    def attr(block, key)
      block.respond_to?(key) ? block.public_send(key) : block[key.to_s]
    end

    def stringify_keys(value)
      case value
      when Hash  then value.transform_keys(&:to_s).transform_values { |v| stringify_keys(v) }
      when Array then value.map { |v| stringify_keys(v) }
      else value
      end
    end

    def build_default_client
      require 'anthropic'
      Anthropic::Client.new(api_key: api_key)
    end

    def api_key
      key = self.class.resolved_api_key
      if key.blank?
        raise ConfigError,
              'Missing Anthropic API key (set ANTHROPIC_API_KEY or anthropic.api_key in ~/.autodev/config.yml)'
      end

      key
    end
  end
end
