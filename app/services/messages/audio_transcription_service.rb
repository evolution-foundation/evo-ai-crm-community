class Messages::AudioTranscriptionService
  include Events::Types
  include Messages::AudioTranscriptionLifecycle
  include Messages::AudioTranscriptionResults
  include Messages::AudioTranscriptionPersistence
  include Messages::AudioTranscriptionProvider
  include Messages::AudioTranscriptionStorage
  pattr_initialize [:attachment!]

  MAX_AUDIO_BYTES = 15 * 1024 * 1024
  # Hard business ceiling shared by UI transcription and agent input. Legacy
  # AUDIO_TRANSCRIPTION_MAX_DURATION_SECONDS values are intentionally ignored.
  MAX_AUDIO_DURATION_SECONDS = 4 * 60
  RETRY_AFTER_PROVIDER_FAILURE = 5.minutes
  LONG_AUDIO_TIMEOUT_THRESHOLD_SECONDS = 60
  HTTP_OPEN_TIMEOUT_SECONDS = 5
  # OpenRouter documents a 60s upstream transcription timeout; leave headroom
  # for its gateway so the Sidekiq worker gets a controlled timeout first.
  HTTP_READ_TIMEOUT_SECONDS = 55
  OPENROUTER_LONG_AUDIO_READ_TIMEOUT_SECONDS = 58

  def perform(for_agent: false)
    initialize_transcription_attempt
    Rails.logger.info "AudioTranscriptionService: Starting for attachment #{attachment.id}"

    preflight_result = prepare_transcription(for_agent)
    return preflight_result if preflight_result

    process_claimed_transcription
  rescue StandardError => e
    Rails.logger.error "AudioTranscriptionService: Error for attachment #{attachment.id}: #{e.class}"
    persist_audio_failure('provider_failed', retry_after: RETRY_AFTER_PROVIDER_FAILURE.from_now) if @transcription_lease_acquired
    { error: 'Audio transcription failed', status: :provider_failed }
  ensure
    @audio_file&.close!
    @transcription_lease&.release
  end

  private

  def transcription_enabled?(for_agent: false)
    if for_agent
      value = GlobalConfigService.load('AUDIO_TRANSCRIPTION_TO_AGENT_ENABLED', 'true')
      return ActiveModel::Type::Boolean.new.cast(value)
    end

    legacy_transcription_enabled?
  end

  def legacy_transcription_enabled?
    global_enabled = GlobalConfigService.load('OPENAI_ENABLE_AUDIO_TRANSCRIPTION', nil)
    return normalized_transcription_config(global_enabled) unless global_enabled.nil?

    openai_hook = Integrations::Hook.find_by(app_id: 'openai')
    return false unless openai_hook&.enabled?

    openai_hook.settings&.[]('enable_audio_transcription') == true
  end

  def normalized_transcription_config(value)
    enabled = if value.is_a?(TrueClass) || value.is_a?(FalseClass)
                value
              else
                %w[true 1 yes on].include?(value.to_s.downcase)
              end
    Rails.logger.info(
      "AudioTranscriptionService: Global config value: #{value.inspect} (#{value.class}), converted to: #{enabled.inspect}"
    )
    Rails.logger.info "AudioTranscriptionService: Transcription #{enabled ? 'enabled' : 'disabled'} via global config"
    enabled
  end

  def transcribe_audio(audio_file: nil, duration: nil)
    return nil unless attachment.file.attached?

    api_key = transcription_api_key
    return nil if api_key.blank?

    transcribe_audio_content(api_key, audio_file, duration)
  rescue StandardError => e
    Rails.logger.error "AudioTranscriptionService: Transcription request failed: #{e.class}"
    @transcription_failure_status = :provider_failed
    nil
  end

  def transcribe_audio_content(api_key, audio_file, duration)
    owns_audio_file = audio_file.nil?
    audio_file ||= download_audio_file
    return unless audio_file
    return unless audio_within_duration_limit?(audio_file, duration: duration)

    call_openai_whisper_api(api_key, audio_file, duration: duration)&.dig('text')
  ensure
    audio_file&.close! if owns_audio_file
  end

  def transcription_api_key
    api_key = openai_api_key
    return api_key if api_key.present?

    # Keep missing credentials distinct from a provider rejection/timeout.
    Rails.logger.warn(
      'AudioTranscriptionService: transcription is enabled but no AI credential resolved ' \
      '(register one under Settings > AI Credentials)'
    )
    @transcription_failure_status = :credentials_unavailable
    nil
  end

  def audio_duration(audio_file)
    Whatsapp::AudioConverterService.audio_duration(audio_file.path)
  end

  def audio_within_duration_limit?(audio_file, duration: nil)
    duration ||= audio_duration(audio_file)
    unless duration
      Rails.logger.warn 'AudioTranscriptionService: Audio duration could not be verified; refusing transcription'
      return false
    end

    max_duration = max_audio_duration_seconds
    if duration > max_duration
      Rails.logger.warn "AudioTranscriptionService: Audio duration exceeds configured limit (#{max_duration}s)"
      return false
    end

    true
  end

  # Whisper is a different endpoint from chat/completions, but the credential is
  # the same one every AI feature resolves. The precedence used to be copied
  # here; it now lives in Ai::CredentialResolver, its single owner.
  def openai_api_key
    credential_endpoint.key
  end

  # Once per message: Whisper host and key come from the same credential.
  def credential_endpoint
    @credential_endpoint ||= Ai::CredentialResolver.resolve_endpoint(for_consumer: :audio_transcription)
  end

  def max_audio_duration_seconds
    MAX_AUDIO_DURATION_SECONDS
  end
end
