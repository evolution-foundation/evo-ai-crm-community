# CRM-212: shared by MessageCreator and SegmentedMessageCreator. A label
# removed mid-turn (e.g. by a stage automation, or the bot's own tool call)
# must not silently drop a reply the turn was already eligible for when it
# started — AgentBotListener stamps that grace window at dispatch time.
module AgentBots::TurnEligibility
  # True while AgentBotListener's turn-start marker for this conversation is
  # still within its TTL (see Redis::RedisKeys::AGENT_BOT_TURN_ELIGIBLE_KEY).
  def turn_was_eligible_at_dispatch?(conversation)
    key = format(Redis::RedisKeys::AGENT_BOT_TURN_ELIGIBLE_KEY, conversation_id: conversation.id)
    Redis::Alfred.get(key).present?
  end
end
