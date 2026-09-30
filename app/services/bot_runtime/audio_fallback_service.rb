# frozen_string_literal: true

module BotRuntime
  # Sends a fixed, user-facing response when audio cannot be processed. The
  # incoming message row serializes concurrent retries and the marker makes the
  # response idempotent across Sidekiq redelivery.
  class AudioFallbackService
    TOO_LONG_TEXT = 'Recebi seu áudio, mas consigo processar áudios de até 4 minutos. Pode reenviá-lo em partes menores ou escrever sua mensagem?'
    UNAVAILABLE_TEXT = 'Recebi seu áudio, mas não consegui processá-lo. Pode escrever a mensagem para mim, por favor?'
    MIXED_FAILURE_TEXT = 'Alguns áudios não puderam ser processados. Envie-os em partes menores, com até 4 minutos cada, ou escreva a mensagem.'
    MARKER_KEY = 'audio_transcription_fallback_for_message_id'

    def self.deliver(event, reasons:)
      new(event, reasons).deliver
    end

    def initialize(event, reasons)
      @event = event
      @reasons = Array(reasons).map(&:to_sym).uniq
    end

    def deliver
      message, conversation, agent_bot = delivery_context
      return false unless message

      delivered = false
      message.with_lock { delivered = deliver_once(message, conversation, agent_bot) }
      delivered
    rescue StandardError => e
      Rails.logger.error("[BotRuntime::AudioFallbackService] delivery failed error_class=#{e.class}")
      false
    end

    private

    def delivery_context
      message = Message.find_by(id: event_value(:message_id))
      conversation = Conversation.find_by(display_id: event_value(:conversation_id))
      agent_bot = AgentBot.find_by(id: event_value(:agent_bot_id))
      return unless valid_message_context?(message, conversation)
      return unless valid_agent_assignment?(conversation, agent_bot)

      [message, conversation, agent_bot]
    end

    def valid_message_context?(message, conversation)
      message&.incoming? && conversation && message.conversation_id == conversation.id
    end

    def valid_agent_assignment?(conversation, agent_bot)
      assignment = conversation.inbox&.agent_bot_inbox
      assignment&.active? && agent_bot && assignment.agent_bot_id == agent_bot.id
    end

    def deliver_once(message, conversation, agent_bot)
      return true if fallback_already_sent?(conversation, message)

      reply = AgentBots::MessageCreator.new(agent_bot).create_bot_reply(
        fallback_text,
        conversation,
        content_attributes: { MARKER_KEY => message.id.to_s }
      )
      reply.present?
    end

    def fallback_text
      return MIXED_FAILURE_TEXT if @reasons.include?(:too_long) && @reasons.include?(:unavailable)
      return TOO_LONG_TEXT if @reasons.include?(:too_long)

      UNAVAILABLE_TEXT
    end

    def fallback_already_sent?(conversation, message)
      conversation.messages.where(message_type: 'outgoing')
                  .exists?(['content_attributes->>? = ?', MARKER_KEY, message.id.to_s])
    end

    def event_value(key)
      @event[key] || @event[key.to_s]
    end
  end
end
