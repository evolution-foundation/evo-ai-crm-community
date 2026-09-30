# frozen_string_literal: true

module Messages
  # Coordinates lease ownership, terminal statuses, persistence, and frontend
  # broadcast while delegating provider I/O to AudioTranscriptionService.
  module AudioTranscriptionLifecycle
    include Events::Types

    private

    def initialize_transcription_attempt
      @transcription_failure_status = nil
      @transcription_lease = nil
      @transcription_lease_acquired = false
      @audio_file = nil
    end

    def prepare_transcription(for_agent)
      return invalid_attachment_result unless attachment.audio?
      return existing_transcription_result if attachment.meta&.[]('transcribed_text').present?
      return disabled_transcription_result unless transcription_enabled?(for_agent: for_agent)

      acquire_transcription_lease
    end

    def invalid_attachment_result
      Rails.logger.warn "AudioTranscriptionService: Attachment #{attachment.id} is not audio"
      { error: 'Attachment is not audio' }
    end

    def existing_transcription_result
      Rails.logger.info "AudioTranscriptionService: Transcription already exists for attachment #{attachment.id}"
      { error: 'Transcription already exists' }
    end

    def disabled_transcription_result
      Rails.logger.warn 'AudioTranscriptionService: Transcription not enabled'
      { error: 'Transcription not enabled', status: :disabled }
    end

    def acquire_transcription_lease
      @transcription_lease = AudioTranscriptionLease.new(attachment)
      lease_status = @transcription_lease.claim
      return { error: 'Transcription already in progress', status: :in_progress } if lease_status == :in_progress
      return completed_lease_result if lease_status == :completed
      return { error: 'Could not acquire transcription lease', status: :lease_unavailable } unless lease_status == :acquired

      @transcription_lease_acquired = true
      nil
    end

    def completed_lease_result
      attachment.reload
      existing_text = attachment.meta&.[]('transcribed_text')
      return { success: true, transcribed_text: existing_text } if existing_text.present?

      { error: 'Could not acquire transcription lease', status: :lease_unavailable }
    end

    def process_claimed_transcription
      # Refresh after claiming: another worker may have completed while this
      # caller was waiting to read the attachment.
      attachment.reload
      existing_text = attachment.meta&.[]('transcribed_text')
      return { success: true, transcribed_text: existing_text } if existing_text.present?
      return backoff_result if retry_after_active?(attachment.meta&.[]('audio_transcription_retry_after'))
      return credentials_unavailable_result if openai_api_key.blank?

      Rails.logger.info 'AudioTranscriptionService: Transcription enabled, starting transcription...'
      @audio_file = download_audio_file
      return audio_unavailable_result unless @audio_file

      transcribe_downloaded_audio(@audio_file)
    end
  end
end
