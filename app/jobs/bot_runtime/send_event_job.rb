# frozen_string_literal: true

module BotRuntime
  class SendEventJob < ApplicationJob
    queue_as :bot_runtime
    retry_on StandardError, wait: :polynomially_longer, attempts: 3
    AUDIO_CONTENTION_RETRY_DELAY = 5.seconds
    # Wait slightly longer than the 2-minute attachment lease so a normal
    # transcription can finish and release it before we choose a terminal reply.
    MAX_AUDIO_CONTENTION_RETRIES = 27

    discard_on BotRuntime::CircuitBreaker::CircuitOpenError do |_job, error|
      Rails.logger.warn "[BotRuntime::SendEventJob] Discarded: #{error.message}"
    end

    def perform(event, audio_contention_retry_attempt = 0)
      Rails.logger.info '[BotRuntime::SendEventJob] Sending event: ' \
                        "conversation_id=#{event[:conversation_id]} agent_bot_id=#{event[:agent_bot_id]}"

      result = enriched_result(event, audio_contention_retry_attempt)
      deliver_result(event, result)
    end

    private

    def enriched_result(event, retry_attempt)
      # Resolve voice notes outside the inbound webhook. Remove raw audio because
      # the current OpenRouter/LiteLLM route rejects audio_url payloads.
      result = BotRuntime::TranscriptionEnricher.enrich(event)
      if result.in_progress
        return schedule_contention_retry(event, retry_attempt) if retry_attempt < MAX_AUDIO_CONTENTION_RETRIES

        Rails.logger.warn '[BotRuntime::SendEventJob] Audio transcription wait budget exhausted'
        result = BotRuntime::TranscriptionEnricher.enrich(event, in_progress_fallback: true)
      end

      result
    end

    def schedule_contention_retry(event, retry_attempt)
      next_attempt = retry_attempt + 1
      self.class.set(wait: AUDIO_CONTENTION_RETRY_DELAY).perform_later(event, next_attempt)
      Rails.logger.info(
        '[BotRuntime::SendEventJob] Audio transcription in progress; retry scheduled ' \
        "attempt=#{next_attempt}/#{MAX_AUDIO_CONTENTION_RETRIES}"
      )
      nil
    end

    def deliver_result(event, result)
      return unless result

      # Audio-only failures get a deterministic CRM reply. Mixed messages keep
      # their text/non-audio media and receive one agent response with the
      # failure context appended by TranscriptionEnricher.
      if result.fallback_reasons.present? && !result.forward_to_agent
        BotRuntime::AudioFallbackService.deliver(event, reasons: result.fallback_reasons)
      end

      unless result.forward_to_agent
        Rails.logger.info '[BotRuntime::SendEventJob] No processable content remains after audio resolution'
        return
      end

      BotRuntime::Client.new.send_event(result.event)

      Rails.logger.info '[BotRuntime::SendEventJob] Event sent successfully: ' \
                        "conversation_id=#{event[:conversation_id]}"
    end
  end
end
