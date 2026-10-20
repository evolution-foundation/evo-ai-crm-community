class AgentBots::ProcessInactivityActionsJob < ApplicationJob
  queue_as :default

  def perform(conversation_id, agent_bot_id)
    Rails.logger.info "[ProcessInactivityActions] === Processing conversation #{conversation_id} with bot #{agent_bot_id} ==="

    conversation = Conversation.find_by(id: conversation_id)
    unless conversation
      Rails.logger.warn "[ProcessInactivityActions] Conversation #{conversation_id} not found"
      return
    end

    agent_bot = AgentBot.find_by(id: agent_bot_id)
    return if Instagram::AmhSafety.blocked_inbox?(conversation.inbox)

    unless agent_bot
      Rails.logger.warn "[ProcessInactivityActions] AgentBot #{agent_bot_id} not found"
      return
    end

    # Verifica se a conversa ainda está elegível (pode ter mudado de status desde o agendamento)
    unless conversation.open? || conversation.pending?
      Rails.logger.debug "[ProcessInactivityActions] Conversation #{conversation_id} no longer open/pending (status: #{conversation.status})"
      return
    end

    # Processa as ações
    service = AgentBots::InactivityActionsService.new(conversation, agent_bot)
    service.process

    Rails.logger.info "[ProcessInactivityActions] === Completed processing conversation #{conversation_id} ==="
  rescue StandardError => e
    Rails.logger.error "[ProcessInactivityActions] Error processing conversation #{conversation_id}: #{e.message}"
    Rails.logger.error e.backtrace.first(10).join("\n")
    # Deixa o Sidekiq fazer retry automático
    raise e
  end
end
