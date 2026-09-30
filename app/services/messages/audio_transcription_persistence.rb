# frozen_string_literal: true

module Messages
  # Atomic metadata writes prevent concurrent UI and agent workers from
  # overwriting each other's lease or transcript state.
  module AudioTranscriptionPersistence
    private

    def persist_audio_failure(reason, retry_after: nil)
      failure_metadata = { audio_transcription_failure: reason }
      failure_metadata[:audio_transcription_retry_after] = retry_after.iso8601 if retry_after
      Attachment.where(id: attachment.id)
                .where("meta->>'transcribed_text' IS NULL")
                .update_all( # rubocop:disable Rails/SkipsModelValidations -- atomic JSONB merge preserves concurrent metadata.
                  ["meta = COALESCE(meta, '{}'::jsonb) || ?::jsonb, updated_at = ?",
                   failure_metadata.to_json, Time.current]
                )
    rescue StandardError => e
      Rails.logger.warn "AudioTranscriptionService: Could not persist failure metadata: #{e.class}"
    end

    def retry_after_active?(value)
      value.present? && Time.zone.parse(value) > Time.current
    rescue ArgumentError, TypeError
      false
    end

    def persist_transcription(transcribed_text)
      updated = Attachment.where(id: attachment.id)
                          .where("meta->>'transcribed_text' IS NULL")
                          .update_all( # rubocop:disable Rails/SkipsModelValidations -- atomic compare-and-set avoids duplicate paid requests.
                            [
                              "meta = (COALESCE(meta, '{}'::jsonb) || ?::jsonb) - " \
                              "'audio_transcription_retry_after' - 'audio_transcription_failure', updated_at = ?",
                              { transcribed_text: transcribed_text }.to_json,
                              Time.current
                            ]
                          )
      return transcribed_text if updated.positive?

      attachment.reload
      attachment.meta&.[]('transcribed_text')
    end
  end
end
