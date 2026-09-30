# frozen_string_literal: true

module Messages
  # Converts provider and persistence outcomes into stable service statuses.
  module AudioTranscriptionResults
    include Events::Types

    private

    def backoff_result
      { error: 'Audio transcription is in retry backoff', status: :backoff }
    end

    def credentials_unavailable_result
      @transcription_failure_status = :credentials_unavailable
      persist_audio_failure('credentials_unavailable')
      { error: 'AI transcription credential unavailable', status: :credentials_unavailable }
    end

    def audio_unavailable_result
      persist_audio_failure('audio_unavailable', retry_after: AudioTranscriptionService::RETRY_AFTER_PROVIDER_FAILURE.from_now)
      { error: 'Audio file unavailable', status: :provider_failed }
    end

    def transcribe_downloaded_audio(audio_file)
      duration = audio_duration(audio_file)
      return duration_unverified_result unless duration
      return duration_exceeded_result if duration > max_audio_duration_seconds

      transcribed_text = transcribe_audio(audio_file: audio_file, duration: duration)
      return transcription_failed_result if transcribed_text.blank?

      save_and_broadcast_transcription(transcribed_text)
    end

    def duration_unverified_result
      Rails.logger.warn "AudioTranscriptionService: Audio duration could not be verified (attachment=#{attachment.id})"
      persist_audio_failure('duration_unverified', retry_after: AudioTranscriptionService::RETRY_AFTER_PROVIDER_FAILURE.from_now)
      { error: 'Audio duration could not be verified', status: :duration_unverified }
    end

    def duration_exceeded_result
      max_duration = max_audio_duration_seconds
      Rails.logger.info "AudioTranscriptionService: Audio exceeds supported duration (#{max_duration}s)"
      persist_audio_failure('duration_exceeded')
      { error: 'Audio exceeds maximum duration', status: :too_long, max_duration_seconds: max_duration }
    end

    def transcription_failed_result
      failure_status = @transcription_failure_status || :provider_failed
      retry_after = AudioTranscriptionService::RETRY_AFTER_PROVIDER_FAILURE.from_now if failure_status == :provider_failed
      persist_audio_failure(failure_status.to_s, retry_after: retry_after)
      { error: 'Transcription failed', status: failure_status }
    end

    def save_and_broadcast_transcription(transcribed_text)
      Rails.logger.info "AudioTranscriptionService: Transcription successful, saving to attachment #{attachment.id}"
      persisted_text = persist_transcription(transcribed_text)
      return persistence_failed_result unless persisted_text

      broadcast_transcription
      Rails.logger.info "AudioTranscriptionService: Transcription saved successfully for attachment #{attachment.id}"
      { success: true, transcribed_text: persisted_text }
    end

    def persistence_failed_result
      persist_audio_failure('provider_failed', retry_after: AudioTranscriptionService::RETRY_AFTER_PROVIDER_FAILURE.from_now)
      { error: 'Could not persist transcription', status: :provider_failed }
    end

    def broadcast_transcription
      attachment.reload
      message = attachment.message
      message.reload
      message.association(:attachments).reset
      Rails.configuration.dispatcher.dispatch(
        MESSAGE_UPDATED,
        Time.zone.now,
        message: message,
        previous_changes: { 'attachments' => [attachment.id] }
      )
    end
  end
end
