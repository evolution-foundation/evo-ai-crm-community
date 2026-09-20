# frozen_string_literal: true

module BotRuntime
  class SendEventJob < ApplicationJob
    queue_as :bot_runtime
    retry_on StandardError, wait: :polynomially_longer, attempts: 3 do |job, error|
      Rails.logger.error "[BotRuntime::SendEventJob] Failed after retries: #{error.message}"
      job.dispatch_typing_off
    end

    discard_on BotRuntime::CircuitBreaker::CircuitOpenError do |job, error|
      Rails.logger.warn "[BotRuntime::SendEventJob] Discarded: #{error.message}"
      job.dispatch_typing_off
    end

    def perform(event)
      Rails.logger.info "[BotRuntime::SendEventJob] Sending event: " \
                        "conversation_id=#{event[:conversation_id]} agent_bot_id=#{event[:agent_bot_id]}"

      BotRuntime::Client.new.send_event(event)

      Rails.logger.info "[BotRuntime::SendEventJob] Event sent successfully: " \
                        "conversation_id=#{event[:conversation_id]}"
    end

    def dispatch_typing_off
      event = arguments.first
      return unless event.is_a?(Hash)

      conversation = Conversation.find_by(display_id: event[:conversation_id] || event['conversation_id'])
      return unless conversation

      agent_bot = conversation.inbox.agent_bot
      return unless agent_bot

      Rails.configuration.dispatcher.dispatch('conversation.typing_off', Time.zone.now, conversation: conversation, user: agent_bot, is_private: false)
    end
  end
end
