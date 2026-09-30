# frozen_string_literal: true

module Messages
  # Bounded ActiveStorage download into a temporary file, with short retries
  # for the object-store upload race.
  module AudioTranscriptionStorage
    private

    MAX_DOWNLOAD_ATTEMPTS = 3
    DOWNLOAD_RETRY_DELAY_SECONDS = 1

    def download_audio_file
      return unless attachment.file.attached?

      MAX_DOWNLOAD_ATTEMPTS.times do |attempt|
        audio_file = download_audio_attempt(attempt)
        return audio_file if audio_file
      end
      nil
    end

    def download_audio_attempt(attempt)
      temp_file = Tempfile.new(['audio', ".#{attachment.extension.presence || 'ogg'}"])
      temp_file.binmode
      return unless write_audio_attachment(temp_file)

      temp_file.rewind
      Rails.logger.info "AudioTranscriptionService: Successfully downloaded audio file (attempt #{attempt + 1})"
      temp_file
    rescue ActiveStorage::FileNotFoundError => e
      temp_file&.close!
      retry_audio_download(attempt, e)
    rescue StandardError => e
      temp_file&.close!
      Rails.logger.error "AudioTranscriptionService: Error downloading audio file: #{e.class}"
      nil
    end

    def write_audio_attachment(temp_file)
      bytes_written = 0
      attachment.file.download do |chunk|
        bytes_written += chunk.bytesize
        return oversized_audio_result(temp_file) if bytes_written > AudioTranscriptionService::MAX_AUDIO_BYTES

        temp_file.write(chunk)
      end
      true
    end

    def oversized_audio_result(temp_file)
      max_bytes = AudioTranscriptionService::MAX_AUDIO_BYTES
      Rails.logger.warn "AudioTranscriptionService: Audio exceeds #{max_bytes} byte limit"
      temp_file.close!
      false
    end

    def retry_audio_download(attempt, error)
      if attempt < MAX_DOWNLOAD_ATTEMPTS - 1
        wait_time = DOWNLOAD_RETRY_DELAY_SECONDS * (2**attempt)
        Rails.logger.warn(
          "AudioTranscriptionService: File not found, retrying in #{wait_time}s " \
          "(attempt #{attempt + 1}/#{MAX_DOWNLOAD_ATTEMPTS})"
        )
        sleep(wait_time)
      else
        Rails.logger.error "AudioTranscriptionService: Download failed after #{MAX_DOWNLOAD_ATTEMPTS} attempts: #{error.class}"
      end
      nil
    end
  end
end
