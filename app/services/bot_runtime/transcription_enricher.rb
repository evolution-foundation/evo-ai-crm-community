# frozen_string_literal: true

module BotRuntime
  # Resolve voice notes before the event reaches the processor. Raw audio is
  # removed because the current chat-completions route rejects audio_url parts.
  class TranscriptionEnricher
    TRANSCRIPT_LABEL = '[Transcrição automática do áudio enviado pelo cliente; pode conter erros. ' \
                       'Use o contexto para interpretar e confirme nomes, datas ou quantidades ambíguas.]'
    TOO_LONG_NOTICE = 'Observação: não consegui processar o áudio porque ele tem mais de 4 minutos. ' \
                      'Pode reenviá-lo em partes menores ou escrever a mensagem.'
    UNAVAILABLE_NOTICE = 'Observação: não consegui processar o áudio. Pode escrever a mensagem para mim?'
    MIXED_FAILURE_NOTICE = 'Observação: alguns áudios não puderam ser processados. ' \
                           'Reenvie-os em partes menores, com até 4 minutos cada, ou escreva a mensagem.'
    RETRY_AFTER = 5.minutes

    Result = Struct.new(:event, :fallback_reasons, :in_progress, :forward_to_agent, keyword_init: true)

    def self.enrich(event, in_progress_fallback: false)
      new(event).enrich(in_progress_fallback: in_progress_fallback)
    end

    def initialize(event)
      @event = event
    end

    def enrich(in_progress_fallback: false)
      message = find_message
      return fail_closed_result unless message || !payload_has_audio?

      audio_attachments = message.attachments.select(&:audio?)
      return payload_has_audio? ? fail_closed_result : unchanged_result unless audio_attachments.any?

      process_audio_attachments(audio_attachments, in_progress_fallback)
    rescue StandardError => e
      Rails.logger.error("[BotRuntime::TranscriptionEnricher] #{e.class}")
      fail_closed_result
    end

    private

    def process_audio_attachments(audio_attachments, in_progress_fallback)
      transcripts = []
      fallback_reasons = []
      audio_attachments.each do |attachment|
        result = consume_transcription(attachment, in_progress_fallback)
        return result if result.is_a?(Result)

        transcripts << result[:transcript] if result[:transcript]
        fallback_reasons << result[:reason] if result[:reason]
      end

      build_result(transcripts, fallback_reasons)
    end

    def consume_transcription(attachment, in_progress_fallback)
      status, text = transcription_for(attachment)
      if status == :in_progress
        return Result.new(event: @event, fallback_reasons: [], in_progress: true, forward_to_agent: false) unless in_progress_fallback

        status = :unavailable
      end

      if status == :transcribed
        { transcript: "#{TRANSCRIPT_LABEL}: #{text}" }
      else
        record_transcription_failure(attachment) if status == :unavailable
        { reason: status == :too_long ? :too_long : :unavailable }
      end
    end

    def build_result(transcripts, fallback_reasons)
      content = [event_value(:message_content).to_s.strip, *transcripts].reject(&:blank?).join("\n\n")
      filtered_attachments = non_audio_payloads
      processable_content = content.present? || filtered_attachments.present?
      response_notice = response_notice_for(fallback_reasons) if fallback_reasons.any? && processable_content
      enriched_event = merge_event(message_content: content, attachments: filtered_attachments)
      enriched_event = merge_event({ response_notice: response_notice }, event: enriched_event) if response_notice.present?

      Result.new(
        event: enriched_event,
        fallback_reasons: fallback_reasons.uniq,
        in_progress: false,
        forward_to_agent: content.present? || filtered_attachments.present?
      )
    end

    def find_message
      message_id = event_value(:message_id)
      return if message_id.blank?

      Message.includes(:attachments).find_by(id: message_id)
    end

    def transcription_for(attachment)
      meta = attachment.meta || {}
      cached_result = cached_transcription(meta)
      return cached_result if cached_result

      result = Messages::AudioTranscriptionService.new(attachment: attachment).perform(for_agent: true)
      normalize_transcription_result(result)
    end

    def cached_transcription(meta)
      return [:transcribed, meta['transcribed_text']] if meta['transcribed_text'].present?
      return [:too_long, nil] if meta['audio_transcription_failure'] == 'duration_exceeded'
      return [:in_progress, nil] if transcription_lease_active?(meta)

      retry_after = meta['audio_transcription_retry_after']
      return [:unavailable, nil] if retry_after.present? && Time.zone.parse(retry_after) > Time.current

      nil
    end

    def normalize_transcription_result(result)
      status = result.is_a?(Hash) ? result[:status]&.to_sym : nil
      return [:in_progress, nil] if status == :in_progress
      return [:too_long, nil] if status == :too_long
      return [:unavailable, nil] unless result.is_a?(Hash) && result[:success]

      [:transcribed, result[:transcribed_text]]
    end

    def transcription_lease_active?(meta)
      expiry = meta['audio_transcription_processing_until']
      expiry.present? && Time.zone.parse(expiry) > Time.current
    rescue ArgumentError, TypeError
      false
    end

    def record_transcription_failure(attachment)
      retry_metadata = { audio_transcription_retry_after: RETRY_AFTER.from_now.iso8601 }
      # Atomic JSONB merge preserves concurrent lease and transcript updates.
      # rubocop:disable Rails/SkipsModelValidations
      Attachment.where(id: attachment.id)
                .where(
                  "meta->>'transcribed_text' IS NULL AND " \
                  "(meta->>'audio_transcription_retry_after' IS NULL OR " \
                  "(meta->>'audio_transcription_retry_after')::timestamptz <= ?)",
                  Time.current
                )
                .update_all(
                  [
                    "meta = COALESCE(meta, '{}'::jsonb) || ?::jsonb, updated_at = ?",
                    retry_metadata.to_json,
                    Time.current
                  ]
                )
      # rubocop:enable Rails/SkipsModelValidations
    end

    # This is carried separately from user content and appended after the model
    # response by Bot Runtime, guaranteeing one reply that handles both parts.
    def response_notice_for(reasons)
      if reasons.include?(:too_long) && reasons.include?(:unavailable)
        MIXED_FAILURE_NOTICE
      elsif reasons.include?(:too_long)
        TOO_LONG_NOTICE
      else
        UNAVAILABLE_NOTICE
      end
    end

    def fail_closed_result
      return unchanged_result unless payload_has_audio?

      filtered = non_audio_payloads
      content = [event_value(:message_content).to_s.strip].reject(&:blank?).join("\n\n")
      processable_content = content.present? || filtered.present?
      sanitized = merge_event(message_content: content, attachments: filtered)
      sanitized = merge_event({ response_notice: UNAVAILABLE_NOTICE }, event: sanitized) if processable_content
      Result.new(
        event: sanitized,
        fallback_reasons: [:unavailable],
        in_progress: false,
        forward_to_agent: content.present? || filtered.present?
      )
    end

    def unchanged_result
      Result.new(event: @event, fallback_reasons: [], in_progress: false, forward_to_agent: true)
    end

    def payload_has_audio?
      Array(event_value(:attachments)).any? { |item| audio_payload?(item) }
    end

    def non_audio_payloads
      Array(event_value(:attachments)).reject { |item| audio_payload?(item) }
    end

    def audio_payload?(payload)
      return false unless payload.is_a?(Hash)

      file_type = payload[:file_type] || payload['file_type']
      file_type.to_s == 'audio'
    end

    def event_value(key)
      @event[key] || @event[key.to_s]
    end

    def merge_event(values = {}, event: @event, **updates)
      values = values.merge(updates)
      string_keys = event.key?(values.keys.first.to_s) && !event.key?(values.keys.first)
      normalized = values.transform_keys { |key| string_keys ? key.to_s : key }
      event.merge(normalized)
    end
  end
end
