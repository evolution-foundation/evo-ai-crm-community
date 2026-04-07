# frozen_string_literal: true

module BotRuntime
  class SendEventJob < ApplicationJob
    queue_as :bot_runtime
    retry_on StandardError, wait: :polynomially_longer, attempts: 3

    discard_on BotRuntime::CircuitBreaker::CircuitOpenError do |_job, error|
      Rails.logger.warn "[BotRuntime::SendEventJob] Discarded: #{error.message}"
    end

    def perform(event)
      Rails.logger.info "[BotRuntime::SendEventJob] Sending event: " \
                        "conversation_id=#{event[:conversation_id]} agent_bot_id=#{event[:agent_bot_id]}"

      BotRuntime::Client.new.send_event(event)

      Rails.logger.info "[BotRuntime::SendEventJob] Event sent successfully: " \
                        "conversation_id=#{event[:conversation_id]}"
    end
  end
end
