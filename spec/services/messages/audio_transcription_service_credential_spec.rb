# frozen_string_literal: true

require 'rails_helper'

# transcription resolves its credential from the registry,
# and the toggle stops meaning "has a key".
RSpec.describe Messages::AudioTranscriptionService do
  let(:attached_file) { instance_double(ActiveStorage::Attached::One, attached?: true) }
  let(:attachment) { instance_double(Attachment, file: attached_file, id: 'attachment-123') }
  let(:service) { described_class.new(attachment: attachment) }

  describe '#transcription_enabled? separates the toggle from the credential (AC4)' do
    it 'stays enabled with the global toggle on even when no credential resolves' do
      allow(GlobalConfigService).to receive(:load)
        .with('OPENAI_ENABLE_AUDIO_TRANSCRIPTION', nil).and_return(true)
      # No credential anywhere: the feature is still ON, it just cannot run.
      allow(Ai::CredentialResolver).to receive(:resolve_key).and_return(nil)

      expect(service.send(:transcription_enabled?)).to be(true)
    end

    it 'is disabled when the global toggle is off, credential or not' do
      allow(GlobalConfigService).to receive(:load)
        .with('OPENAI_ENABLE_AUDIO_TRANSCRIPTION', nil).and_return(false)
      allow(Ai::CredentialResolver).to receive(:resolve_key).and_return('sk-usable')

      expect(service.send(:transcription_enabled?)).to be(false)
    end

    it 'accepts string values for the global toggle' do
      %w[true 1 yes on].each do |truthy|
        allow(GlobalConfigService).to receive(:load)
          .with('OPENAI_ENABLE_AUDIO_TRANSCRIPTION', nil).and_return(truthy)

        expect(service.send(:transcription_enabled?)).to be(true)
      end

      %w[false 0 no off].each do |falsy|
        allow(GlobalConfigService).to receive(:load)
          .with('OPENAI_ENABLE_AUDIO_TRANSCRIPTION', nil).and_return(falsy)

        expect(service.send(:transcription_enabled?)).to be(false)
      end
    end

    context 'when the global toggle is unset and the hook decides' do
      before do
        allow(GlobalConfigService).to receive(:load)
          .with('OPENAI_ENABLE_AUDIO_TRANSCRIPTION', nil).and_return(nil)
      end

      it 'is enabled by the hook toggle alone, with no api_key in settings' do
        hook = instance_double(Integrations::Hook, enabled?: true,
                                                   settings: { 'enable_audio_transcription' => true })
        allow(Integrations::Hook).to receive(:find_by).with(app_id: 'openai').and_return(hook)

        # Before this story the same settings without 'api_key' returned false,
        # so a missing credential looked exactly like a disabled feature.
        expect(service.send(:transcription_enabled?)).to be(true)
      end

      it 'is disabled when the hook toggle is off' do
        hook = instance_double(Integrations::Hook, enabled?: true,
                                                   settings: { 'enable_audio_transcription' => false })
        allow(Integrations::Hook).to receive(:find_by).with(app_id: 'openai').and_return(hook)

        expect(service.send(:transcription_enabled?)).to be(false)
      end

      it 'is disabled when there is no hook at all' do
        allow(Integrations::Hook).to receive(:find_by).with(app_id: 'openai').and_return(nil)

        expect(service.send(:transcription_enabled?)).to be(false)
      end
    end
  end

  describe '#openai_api_key delegates to the resolver (AC1)' do
    it 'asks the resolver for the audio_transcription consumer' do
      expect(Ai::CredentialResolver).to receive(:resolve_endpoint)
        .with(for_consumer: :audio_transcription)
        .and_return(Ai::CredentialResolver::Endpoint.new(key: 'sk-from-registry', base_url: nil, provider: nil))

      expect(service.send(:openai_api_key)).to eq('sk-from-registry')
    end

    it 'does not read GlobalConfigService directly any more' do
      # The duplicated precedence chain was deleted, not adapted: it lives in
      # Ai::CredentialResolver, and reading it here would fork the rule again.
      allow(Ai::CredentialResolver).to receive(:resolve_endpoint)
        .and_return(Ai::CredentialResolver::Endpoint.new(key: 'sk-from-registry', base_url: nil, provider: nil))
      expect(GlobalConfigService).not_to receive(:load).with('OPENAI_API_SECRET', nil)

      service.send(:openai_api_key)
    end
  end

  describe '#transcribe_audio without a credential (AC5)' do
    it 'does not call Whisper and records the reason' do
      allow(Ai::CredentialResolver).to receive(:resolve_endpoint)
        .and_return(Ai::CredentialResolver::Endpoint.new(key: nil, base_url: nil, provider: nil))
      allow(Rails.logger).to receive(:warn)

      expect(service).not_to receive(:call_openai_whisper_api)
      expect(service.send(:transcribe_audio)).to be_nil
      expect(Rails.logger).to have_received(:warn).with(/no AI credential resolved/)
    end
  end

  describe 'transcription-specific provider configuration' do
    def stub_audio_attachment
      allow(attachment).to receive_messages(audio?: true, meta: {})
      allow(attachment).to receive(:file).and_return(attached_file)
      allow(attachment).to receive(:reload).and_return(attachment)
      allow(attachment).to receive(:message)
        .and_return(instance_double(Message, reload: true, association: instance_double(ActiveRecord::Associations::CollectionProxy, reset: true)))
    end

    def stub_transcription_service(audio_file, duration)
      allow(service).to receive_messages(openai_api_key: 'test-key', download_audio_file: audio_file)
      allow(service).to receive(:audio_duration).with(audio_file).and_return(duration)
      allow(service).to receive(:max_audio_duration_seconds).and_return(240)
      allow(service).to receive(:transcribe_audio).with(audio_file: audio_file, duration: duration).and_return('Olá')
    end

    def stub_lease_and_persistence
      allow(Messages::AudioTranscriptionLease).to receive(:new)
        .with(attachment).and_return(instance_double(Messages::AudioTranscriptionLease, claim: :acquired, release: true))
      relation = instance_double(ActiveRecord::Relation, update_all: 1)
      allow(relation).to receive(:where).and_return(relation)
      allow(Attachment).to receive(:where).with(id: attachment.id).and_return(relation)
      allow(Rails.configuration.dispatcher).to receive(:dispatch)
    end

    it 'selects the Groq Whisper model when no explicit transcription model is set' do
      allow(GlobalConfigService).to receive(:load).with('AUDIO_TRANSCRIPTION_MODEL', nil).and_return(nil)

      expect(service.send(:transcription_model, 'https://api.groq.com/openai/v1')).to eq('whisper-large-v3')
    end

    it 'selects the OpenRouter model separately from the chat model' do
      allow(GlobalConfigService).to receive(:load).with('AUDIO_TRANSCRIPTION_MODEL', nil).and_return(nil)

      expect(service.send(:transcription_model, 'https://openrouter.ai/api/v1')).to eq('openai/whisper-large-v3')
    end

    it 'uses the winning provider endpoint when its credential has no custom base URL' do
      endpoint = instance_double(Ai::CredentialResolver::Endpoint, provider: 'openrouter', base_url: nil)
      allow(service).to receive(:credential_endpoint).and_return(endpoint)
      allow(GlobalConfigService).to receive(:load)
        .with('OPENAI_API_URL', 'https://api.openai.com/v1').and_return('https://legacy-openai.example/v1')

      expect(service.send(:transcription_base_url)).to eq('https://openrouter.ai/api/v1')
    end

    it 'uses Groq’s endpoint when its credential has no custom base URL' do
      endpoint = instance_double(Ai::CredentialResolver::Endpoint, provider: 'groq', base_url: nil)
      allow(service).to receive(:credential_endpoint).and_return(endpoint)

      expect(service.send(:transcription_base_url)).to eq('https://api.groq.com/openai/v1')
    end

    it 'uses the selected provider model behind a custom credential endpoint' do
      endpoint = instance_double(Ai::CredentialResolver::Endpoint, provider: 'openrouter', base_url: nil)
      allow(service).to receive(:credential_endpoint).and_return(endpoint)
      allow(GlobalConfigService).to receive(:load).with('AUDIO_TRANSCRIPTION_MODEL', nil).and_return(nil)

      expect(service.send(:transcription_model, 'https://proxy.example.test/v1'))
        .to eq('openai/whisper-large-v3')
    end

    it 'honors an explicitly configured transcription model' do
      allow(GlobalConfigService).to receive(:load)
        .with('AUDIO_TRANSCRIPTION_MODEL', nil).and_return('whisper-large-v3-turbo')

      expect(service.send(:transcription_model, 'https://api.openai.com/v1')).to eq('whisper-large-v3-turbo')
    end

    it 'appends the transcription endpoint to an OpenRouter base URL without duplicate path segments' do
      uri = service.send(:transcription_uri, 'https://openrouter.ai/api/v1/')

      expect(uri.host).to eq('openrouter.ai')
      expect(uri.request_uri).to eq('/api/v1/audio/transcriptions')
    end

    it 'rejects an unsafe or malformed transcription endpoint URL' do
      expect { service.send(:transcription_uri, 'javascript:alert(1)') }
        .to raise_error(URI::InvalidURIError)
    end

    it 'rejects a plaintext transcription endpoint so API keys are never sent over HTTP' do
      expect { service.send(:transcription_uri, 'http://openrouter.ai/api/v1') }
        .to raise_error(URI::InvalidURIError)
    end

    it 'sends the selected transcription model in the multipart request' do
      endpoint = instance_double(Ai::CredentialResolver::Endpoint,
                                 provider: 'groq', base_url: 'https://api.groq.com/openai/v1/')
      allow(service).to receive(:credential_endpoint).and_return(endpoint)
      allow(GlobalConfigService).to receive(:load).with('AUDIO_TRANSCRIPTION_MODEL', nil).and_return(nil)
      allow(GlobalConfigService).to receive(:load).with('DEFAULT_LOCALE', nil).and_return('pt-BR')

      request = Net::HTTP::Post.new('/openai/v1/audio/transcriptions')
      expect(request).to receive(:set_form) do |form_data, content_type|
        expect(form_data).to include(%w[model whisper-large-v3])
        expect(content_type).to eq('multipart/form-data')
      end
      allow(Net::HTTP::Post).to receive(:new).and_return(request)

      response = instance_double(Net::HTTPOK, code: '200', body: '{"text":"ok"}')
      http = instance_double(Net::HTTP)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:request).with(request).and_return(response)
      allow(Net::HTTP).to receive(:new).with('api.groq.com', 443).and_return(http)
      allow(attachment).to receive(:extension).and_return('ogg')
      allow(service).to receive(:audio_duration).and_return(30)

      Tempfile.create(['voice', '.ogg']) do |audio_file|
        expect(service.send(:call_openai_whisper_api, 'test-key', audio_file)).to eq('text' => 'ok')
      end
    end

    it 'uses a fixed four-minute duration ceiling, independent of legacy config values' do
      expect(GlobalConfigService).not_to receive(:load).with('AUDIO_TRANSCRIPTION_MAX_DURATION_SECONDS', anything)
      expect(service.send(:max_audio_duration_seconds)).to eq(240)
    end

    it 'uses duration tiers for OpenRouter while keeping shorter and other-provider calls bounded' do
      expect(service.send(:transcription_read_timeout, 45, provider: 'openrouter')).to eq(55)
      expect(service.send(:transcription_read_timeout, 180, provider: 'openrouter')).to eq(58)
      expect(service.send(:transcription_read_timeout, 180, provider: 'groq')).to eq(55)
    end

    it 'does not call the provider when another transcription job owns the lease' do
      allow(attachment).to receive(:audio?).and_return(true)
      allow(attachment).to receive(:meta).and_return('audio_transcription_processing_until' => 1.minute.from_now.iso8601)
      allow(service).to receive(:transcription_enabled?).with(for_agent: false).and_return(true)

      expect(service).not_to receive(:persist_audio_failure)
      expect(service).not_to receive(:transcribe_audio)
      expect(service.perform).to eq(error: 'Transcription already in progress', status: :in_progress)
    end

    it 'reports a lease storage error separately from real contention without recording provider backoff' do
      allow(attachment).to receive(:audio?).and_return(true)
      allow(attachment).to receive(:meta).and_return({})
      allow(service).to receive(:transcription_enabled?).with(for_agent: true).and_return(true)
      lease = instance_double(Messages::AudioTranscriptionLease, claim: :unavailable, release: true)
      allow(Messages::AudioTranscriptionLease).to receive(:new).with(attachment).and_return(lease)

      expect(service).not_to receive(:persist_audio_failure)
      expect(service).not_to receive(:transcribe_audio)
      expect(service.perform(for_agent: true)).to eq(
        error: 'Could not acquire transcription lease', status: :lease_unavailable
      )
    end

    it 'reuses a transcript persisted by another worker before this worker acquired its lease' do
      allow(attachment).to receive(:audio?).and_return(true)
      allow(attachment).to receive(:meta).and_return({})
      allow(service).to receive(:transcription_enabled?).with(for_agent: true).and_return(true)
      lease = instance_double(Messages::AudioTranscriptionLease, claim: :acquired, release: true)
      allow(Messages::AudioTranscriptionLease).to receive(:new).with(attachment).and_return(lease)
      allow(attachment).to receive(:reload) do
        allow(attachment).to receive(:meta).and_return('transcribed_text' => 'já salvo')
        attachment
      end
      expect(service).not_to receive(:openai_api_key)
      expect(service).not_to receive(:transcribe_audio)

      expect(service.perform(for_agent: true)).to eq(success: true, transcribed_text: 'já salvo')
    end

    it 'rejects audio longer than four minutes in every transcription path before calling the provider' do
      expect(service).not_to receive(:call_openai_whisper_api)
      [true, false].each do |for_agent|
        allow(attachment).to receive(:audio?).and_return(true)
        allow(attachment).to receive(:meta).and_return({})
        allow(attachment).to receive(:file)
          .and_return(instance_double(ActiveStorage::Attached::One, attached?: true))
        allow(attachment).to receive(:reload).and_return(attachment)
        allow(service).to receive(:transcription_enabled?).with(for_agent: for_agent).and_return(true)
        allow(service).to receive(:openai_api_key).and_return('test-key')
        lease = instance_double(Messages::AudioTranscriptionLease, claim: :acquired, release: true)
        allow(Messages::AudioTranscriptionLease).to receive(:new).with(attachment).and_return(lease)
        audio_file = instance_double(Tempfile, path: '/tmp/long-audio.ogg', close!: true)
        allow(service).to receive(:download_audio_file).and_return(audio_file)
        allow(service).to receive(:audio_duration).with(audio_file).and_return(241)
        allow(service).to receive(:max_audio_duration_seconds).and_return(240)
        allow(service).to receive(:persist_audio_failure).with('duration_exceeded')
        expect(service.perform(for_agent: for_agent)).to eq(
          error: 'Audio exceeds maximum duration', status: :too_long, max_duration_seconds: 240
        )
      end
    end

    it 'fails closed with a distinct status when duration cannot be verified' do
      allow(attachment).to receive(:audio?).and_return(true)
      allow(attachment).to receive(:meta).and_return({})
      allow(attachment).to receive(:file)
        .and_return(instance_double(ActiveStorage::Attached::One, attached?: true))
      allow(attachment).to receive(:reload).and_return(attachment)
      allow(service).to receive(:transcription_enabled?).with(for_agent: true).and_return(true)
      allow(service).to receive(:openai_api_key).and_return('test-key')
      lease = instance_double(Messages::AudioTranscriptionLease, claim: :acquired, release: true)
      allow(Messages::AudioTranscriptionLease).to receive(:new).with(attachment).and_return(lease)
      audio_file = instance_double(Tempfile, path: '/tmp/unknown-audio.ogg', close!: true)
      allow(service).to receive(:download_audio_file).and_return(audio_file)
      allow(service).to receive(:audio_duration).with(audio_file).and_return(nil)

      expect(service).to receive(:persist_audio_failure)
        .with('duration_unverified', retry_after: kind_of(ActiveSupport::TimeWithZone))
      expect(service).not_to receive(:call_openai_whisper_api)
      expect(service.perform(for_agent: true)).to eq(
        error: 'Audio duration could not be verified', status: :duration_unverified
      )
    end

    it 'honors a persisted provider retry window for the UI path without calling the provider' do
      allow(attachment).to receive(:audio?).and_return(true)
      allow(attachment).to receive(:meta).and_return({})
      allow(service).to receive(:transcription_enabled?).with(for_agent: false).and_return(true)
      lease = instance_double(Messages::AudioTranscriptionLease, claim: :acquired, release: true)
      allow(Messages::AudioTranscriptionLease).to receive(:new).with(attachment).and_return(lease)
      allow(attachment).to receive(:reload) do
        allow(attachment).to receive(:meta).and_return(
          'audio_transcription_retry_after' => 2.minutes.from_now.iso8601
        )
        attachment
      end
      expect(service).not_to receive(:openai_api_key)

      expect(service.perform).to eq(error: 'Audio transcription is in retry backoff', status: :backoff)
    end

    it 'allows audio up to and including four minutes in both transcription paths' do
      audio_file = instance_double(Tempfile, path: '/tmp/four-minute-audio.ogg', close!: true)
      stub_audio_attachment
      stub_transcription_service(audio_file, 240)
      stub_lease_and_persistence
      expect(service).to receive(:transcribe_audio)
        .with(audio_file: audio_file, duration: 240).twice.and_return('Olá')

      [true, false].each do |for_agent|
        allow(service).to receive(:transcription_enabled?).with(for_agent: for_agent).and_return(true)
        expect(service.perform(for_agent: for_agent)).to eq(success: true, transcribed_text: 'Olá')
      end
    end

    it 'releases its lease after a provider error' do
      allow(attachment).to receive(:audio?).and_return(true)
      allow(attachment).to receive(:meta).and_return({})
      allow(attachment).to receive(:reload).and_return(attachment)
      allow(service).to receive(:transcription_enabled?).with(for_agent: false).and_return(true)
      allow(service).to receive(:openai_api_key).and_return('test-key')
      audio_file = instance_double(Tempfile, path: '/tmp/audio.ogg', close!: true)
      allow(service).to receive(:download_audio_file).and_return(audio_file)
      allow(service).to receive(:audio_duration).with(audio_file).and_return(30)
      allow(service).to receive(:max_audio_duration_seconds).and_return(240)

      relation = instance_double(ActiveRecord::Relation, update_all: 1)
      allow(Attachment).to receive(:where).with(id: attachment.id).and_return(relation)
      allow(relation).to receive(:where).and_return(relation)
      allow(relation).to receive(:update_all).and_return(1)
      allow(service).to receive(:transcribe_audio).and_raise(Net::ReadTimeout)

      service.perform

      expect(relation).to have_received(:update_all).thrice
    end

    it 'persists a generic failure and retry timestamp as one atomic JSONB merge' do
      relation = instance_double(ActiveRecord::Relation)
      allow(Attachment).to receive(:where).with(id: attachment.id).and_return(relation)
      allow(relation).to receive(:where).and_return(relation)
      expect(relation).to receive(:update_all) do |statement|
        metadata = JSON.parse(statement.fetch(1))
        expect(metadata['audio_transcription_failure']).to eq('provider_failed')
        expect(Time.zone.parse(metadata['audio_transcription_retry_after'])).to be_within(2.seconds).of(5.minutes.from_now)
      end

      service.send(:persist_audio_failure, 'provider_failed', retry_after: 5.minutes.from_now)
    end

    it 'atomically permits only one transcription lease per attachment' do
      record = Attachment.new(
        attachable_type: 'Message',
        attachable_id: SecureRandom.uuid,
        file_type: :audio,
        meta: {}
      )
      record.save!(validate: false)
      first = Messages::AudioTranscriptionLease.new(record)
      second = Messages::AudioTranscriptionLease.new(record.reload)

      expect(first.claim).to eq(:acquired)
      expect(second.claim).to eq(:in_progress)

      first.release
      expect(second.claim).to eq(:acquired)

      second.release
      # rubocop:disable Rails/SkipsModelValidations -- exercise expired-lease CAS against persisted JSONB.
      record.update_columns(meta: { 'audio_transcription_processing_until' => 1.second.ago.iso8601 })
      # rubocop:enable Rails/SkipsModelValidations
      expect(Messages::AudioTranscriptionLease.new(record.reload).claim).to eq(:acquired)
    ensure
      second&.release
      record&.destroy!
    end

    it 'reports database errors while claiming a lease as unavailable, not contention' do
      record = Attachment.new(
        attachable_type: 'Message',
        attachable_id: SecureRandom.uuid,
        file_type: :audio,
        meta: {}
      )
      record.save!(validate: false)
      lease = Messages::AudioTranscriptionLease.new(record)
      allow(Attachment).to receive(:where).with(id: record.id).and_raise(ActiveRecord::StatementInvalid, 'database unavailable')

      expect(lease.claim).to eq(:unavailable)
    ensure
      record&.destroy!
    end
  end
end
