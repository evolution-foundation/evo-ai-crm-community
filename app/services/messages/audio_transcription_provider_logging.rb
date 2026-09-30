# frozen_string_literal: true

module Messages
  # Emits aggregate provider timing only; deliberately never logs payloads,
  # credentials, transcript text, or personal information.
  module AudioTranscriptionProviderLogging
    private

    def log_provider_request_started(provider, duration, duration_band, read_timeout)
      Rails.logger.info(
        "AudioTranscriptionService: Provider request started provider=#{provider.presence || 'custom'} " \
        "audio_duration_band=#{duration_band} audio_duration_seconds=#{duration.round(2)} " \
        "read_timeout_seconds=#{read_timeout}"
      )
    end

    def log_provider_request_finished(provider, duration, duration_band, elapsed_ms, status)
      Rails.logger.info(
        "AudioTranscriptionService: Provider request finished provider=#{provider.presence || 'custom'} " \
        "audio_duration_band=#{duration_band} audio_duration_seconds=#{duration.round(2)} " \
        "elapsed_ms=#{elapsed_ms} http_status=#{status}"
      )
    end

    def log_provider_request_failure(provider, duration, started_at, read_timeout, error)
      elapsed_ms = elapsed_provider_request_ms(started_at) if started_at
      duration_band = audio_duration_band(duration)
      Rails.logger.error(
        "AudioTranscriptionService: Provider request failed provider=#{provider.presence || 'custom'} " \
        "audio_duration_band=#{duration_band} audio_duration_seconds=#{duration&.round(2) || 'unknown'} " \
        "elapsed_ms=#{elapsed_ms || 'unknown'} read_timeout_seconds=#{read_timeout || 'unknown'} " \
        "error_class=#{error.class}"
      )
    end

    def audio_duration_band(duration)
      return 'unknown' unless duration

      duration <= AudioTranscriptionService::LONG_AUDIO_TIMEOUT_THRESHOLD_SECONDS ? 'short' : 'long'
    end

    def elapsed_provider_request_ms(started_at)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    end
  end
end
