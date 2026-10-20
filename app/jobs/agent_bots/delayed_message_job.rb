class AgentBots::DelayedMessageJob < ApplicationJob
  queue_as :default

  def perform(agent_bot_id, segments, conversation_id, segment_index)
    Rails.logger.info '[AgentBot DelayedMessageJob] === JOB STARTED ==='
    Rails.logger.info "[AgentBot DelayedMessageJob] Agent Bot ID: #{agent_bot_id}"
    Rails.logger.info "[AgentBot DelayedMessageJob] Conversation ID: #{conversation_id}"
    Rails.logger.info "[AgentBot DelayedMessageJob] Segment Index: #{segment_index}"
    Rails.logger.info "[AgentBot DelayedMessageJob] Total Segments: #{segments.length}"

    agent_bot = AgentBot.find(agent_bot_id)
    conversation = Conversation.find(conversation_id)
    return if Instagram::AmhSafety.blocked_inbox?(conversation.inbox)

    Rails.logger.info "[AgentBot DelayedMessageJob] Processing segment #{segment_index} for conversation #{conversation_id}"
    Rails.logger.info "[AgentBot DelayedMessageJob] Current conversation status: #{conversation.status}"

    unless conversation_eligible_for_bot_reply?(conversation)
      Rails.logger.warn "[AgentBot DelayedMessageJob] ⚠️  Conversation #{conversation_id} no longer eligible (status: #{conversation.status})"
      Rails.logger.warn "[AgentBot DelayedMessageJob] ⚠️  Skipping delayed message for segment #{segment_index}"
      return
    end

    # Processa o segmento atual
    current_segment = segments[segment_index]
    Rails.logger.info "[AgentBot DelayedMessageJob] Segment Preview: #{current_segment[0..100]}#{'...' if current_segment.length > 100}"

    Rails.logger.info '[AgentBot DelayedMessageJob] ✅ Conversation eligible, creating message'
    message_creator = AgentBots::SegmentedMessageCreator.new(agent_bot)
    message_creator.process_segment_message(current_segment, conversation)
    Rails.logger.info "[AgentBot DelayedMessageJob] ✅ Message created successfully for segment #{segment_index}"

    # Agenda o próximo segmento na cadeia se houver
    next_segment_index = segment_index + 1
    if next_segment_index < segments.length
      Rails.logger.info "[AgentBot DelayedMessageJob] Scheduling next segment #{next_segment_index}"
      message_creator.schedule_next_segment(segments, next_segment_index, conversation)
    else
      Rails.logger.info '[AgentBot DelayedMessageJob] ✅ All segments processed - chain complete'
    end

  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error "[AgentBot DelayedMessageJob] Record not found: #{e.message}"
  rescue StandardError => e
    Rails.logger.error "[AgentBot DelayedMessageJob] Error processing delayed message: #{e.message}"
    raise e
  end

  private

  def conversation_eligible_for_bot_reply?(conversation)
    conversation_status = conversation.status
    is_pending = conversation_status == 'pending'
    Rails.logger.debug { "[AgentBot DelayedMessageJob] Conversation status check: #{conversation_status} -> pending: #{is_pending}" }
    is_pending
  end
end
