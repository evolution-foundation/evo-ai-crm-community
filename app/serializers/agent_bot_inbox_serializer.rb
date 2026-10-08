# frozen_string_literal: true

# One agent_bot ↔ inbox binding, as the agent's Channels tab reads it (CRM-41).
module AgentBotInboxSerializer
  extend self

  def serialize(agent_bot_inbox, include_inbox: false)
    return nil unless agent_bot_inbox

    result = {
      id: agent_bot_inbox.id,
      agent_bot_id: agent_bot_inbox.agent_bot_id,
      inbox_id: agent_bot_inbox.inbox_id,
      status: agent_bot_inbox.status,
      configuration: AgentBotSerializer.serialize_agent_bot_inbox_configuration(agent_bot_inbox),
      created_at: agent_bot_inbox.created_at&.iso8601,
      updated_at: agent_bot_inbox.updated_at&.iso8601
    }
    result[:inbox] = InboxSerializer.serialize(agent_bot_inbox.inbox) if include_inbox
    result
  end

  def serialize_collection(agent_bot_inboxes, **options)
    return [] unless agent_bot_inboxes

    agent_bot_inboxes.map { |agent_bot_inbox| serialize(agent_bot_inbox, **options) }
  end
end
