# frozen_string_literal: true

module Messages
  # OpenAI-compatible provider endpoint selection and the bounded HTTP request.
  module AudioTranscriptionProvider
    include AudioTranscriptionProviderLogging

    private

    def transcription_base_url
      endpoint = credential_endpoint
      return endpoint.base_url if endpoint.base_url.present?

      case endpoint.provider
      when 'groq'
        'https://api.groq.com/openai/v1'
      when 'openrouter'
        'https://openrouter.ai/api/v1'
      else
        GlobalConfigService.load('OPENAI_API_URL', 'https://api.openai.com/v1')
      end
    end

    def transcription_model(base_url)
      configured = GlobalConfigService.load('AUDIO_TRANSCRIPTION_MODEL', nil).to_s.strip
      return configured if configured.present?

      model_for_endpoint(base_url) || 'whisper-1'
    rescue URI::InvalidURIError, TypeError
      'whisper-1'
    end

    def model_for_endpoint(base_url)
      host = URI.parse(base_url).host.to_s.downcase
      return 'whisper-large-v3' if host == 'api.groq.com' || host.end_with?('.groq.com')
      return 'openai/whisper-large-v3' if host == 'openrouter.ai' || host.end_with?('.openrouter.ai')
      return 'whisper-large-v3' if credential_endpoint.provider == 'groq'
      return 'openai/whisper-large-v3' if credential_endpoint.provider == 'openrouter'

      nil
    end

    def transcription_uri(base_url)
      uri = URI.parse(base_url)
      raise URI::InvalidURIError unless uri.scheme == 'https' && uri.host.present?

      base_path = uri.path.to_s.sub(%r{/+\z}, '')
      uri.path = "#{base_path}/audio/transcriptions"
      uri.query = nil
      uri.fragment = nil
      uri
    end

    def call_openai_whisper_api(api_key, audio_file, duration: nil)
      require 'net/http'
      require 'uri'

      base_url = transcription_base_url
      uri = transcription_uri(base_url.to_s)
      duration ||= audio_duration(audio_file)
      provider = credential_endpoint.provider.to_s
      read_timeout = transcription_read_timeout(duration, provider: provider)
      duration_band = audio_duration_band(duration)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      log_provider_request_started(provider, duration, duration_band, read_timeout)
      response = perform_provider_request(uri, base_url, api_key, audio_file, read_timeout)
      elapsed_ms = elapsed_provider_request_ms(started_at)
      log_provider_request_finished(provider, duration, duration_band, elapsed_ms, response.code)
      parse_provider_response(response)
    rescue StandardError => e
      log_provider_request_failure(provider, duration, started_at, read_timeout, e)
      @transcription_failure_status = :provider_failed
      nil
    end

    def perform_provider_request(uri, base_url, api_key, audio_file, read_timeout)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = AudioTranscriptionService::HTTP_OPEN_TIMEOUT_SECONDS
      http.read_timeout = read_timeout

      request = Net::HTTP::Post.new(uri.request_uri)
      request['Authorization'] = "Bearer #{api_key}"
      filename = "audio.#{attachment.extension.presence || 'ogg'}"
      form_data = [['file', audio_file, { filename: filename }], ['model', transcription_model(base_url)]]
      detected_language = detect_language
      form_data << ['language', detected_language] if detected_language.present?
      request.set_form(form_data, 'multipart/form-data')
      http.request(request)
    end

    def transcription_read_timeout(duration, provider:)
      return AudioTranscriptionService::HTTP_READ_TIMEOUT_SECONDS unless provider == 'openrouter'
      if duration.nil? || duration <= AudioTranscriptionService::LONG_AUDIO_TIMEOUT_THRESHOLD_SECONDS
        return AudioTranscriptionService::HTTP_READ_TIMEOUT_SECONDS
      end

      AudioTranscriptionService::OPENROUTER_LONG_AUDIO_READ_TIMEOUT_SECONDS
    end

    def parse_provider_response(response)
      return JSON.parse(response.body) if response.code == '200'

      Rails.logger.warn "AudioTranscriptionService: Provider rejected transcription (HTTP #{response.code})"
      nil
    end

    def detect_language
      locale = GlobalConfigService.load('DEFAULT_LOCALE', nil)
      return 'pt' if locale&.start_with?('pt')
      return 'es' if locale&.start_with?('es')
      return 'fr' if locale&.start_with?('fr')
      return 'de' if locale&.start_with?('de')
      return 'it' if locale&.start_with?('it')

      nil
    end
  end
end
