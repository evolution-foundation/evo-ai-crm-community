# frozen_string_literal: true

module Templates
  module CategoryImporters
    # Creates AgentBots with secrets forcibly nil. User must reconfigure
    # api_key and outgoing_url in the agent settings before the bot will work.
    class AgentsImporter < Base
      CATEGORY = 'agents'
      MODEL = ::AgentBot
      UNIQUE_FIELD = :name

      private

      def attributes_for(item)
        attrs = item.except('slug')
        # Defense in depth: zero secrets even if Sanitizer.zero_blocked_fields! missed.
        attrs['api_key'] = nil
        attrs['outgoing_url'] = nil
        attrs
      end
    end
  end
end
