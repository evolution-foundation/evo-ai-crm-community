# frozen_string_literal: true

module Templates
  # No-op replacement for Rails.configuration.dispatcher during bulk import.
  # Prevents WebSocket/webhook broadcasts when creating hundreds of entities.
  #
  # Caveat: does NOT suppress Wisper publishes (some models use
  # `include Wisper::Publisher` independently). Wisper events in the import
  # path are accepted as a known limitation; they don't affect DB state.
  class NullDispatcher
    def dispatch(*); end
    def listeners; []; end
    def load_listeners; end
  end
end
