# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BotRuntime::SendEventJob, type: :job do
  let(:event) do
    {
      conversation_id: 'conversation-1',
      agent_bot_id: 'bot-1',
      message_id: 'incoming-1',
      message_content: '',
      attachments: [{ url: 'https://media.invalid/audio', file_type: 'audio' }]
    }
  end

  it 'keeps the bounded contention window longer than the lease expiration' do
    wait_budget = described_class::AUDIO_CONTENTION_RETRY_DELAY * described_class::MAX_AUDIO_CONTENTION_RETRIES

    expect(described_class::MAX_AUDIO_CONTENTION_RETRIES).to eq(27)
    expect(wait_budget).to be > Messages::AudioTranscriptionLease::DURATION
  end

  it 're-enqueues lease contention without sending the untranscribed audio to Bot Runtime' do
    pending_result = BotRuntime::TranscriptionEnricher::Result.new(
      event: event, fallback_reasons: [], in_progress: true, forward_to_agent: false
    )
    delayed_job = instance_double(ActiveJob::ConfiguredJob, perform_later: true)
    allow(BotRuntime::TranscriptionEnricher).to receive(:enrich).with(event).and_return(pending_result)
    expect(described_class).to receive(:set).with(wait: described_class::AUDIO_CONTENTION_RETRY_DELAY)
                                            .and_return(delayed_job)
    expect(BotRuntime::Client).not_to receive(:new)

    described_class.new.perform(event)

    expect(delayed_job).to have_received(:perform_later).with(event, 1)
  end

  it 'sends one generic fallback after the bounded lease wait expires' do
    pending_result = BotRuntime::TranscriptionEnricher::Result.new(
      event: event, fallback_reasons: [], in_progress: true, forward_to_agent: false
    )
    terminal_result = BotRuntime::TranscriptionEnricher::Result.new(
      event: event.merge(attachments: [], message_content: ''),
      fallback_reasons: [:unavailable], in_progress: false, forward_to_agent: false
    )
    allow(BotRuntime::TranscriptionEnricher).to receive(:enrich).with(event).and_return(pending_result)
    allow(BotRuntime::TranscriptionEnricher).to receive(:enrich)
      .with(event, in_progress_fallback: true).and_return(terminal_result)
    expect(BotRuntime::AudioFallbackService).to receive(:deliver).with(event, reasons: [:unavailable])
    expect(BotRuntime::Client).not_to receive(:new)

    described_class.new.perform(event, described_class::MAX_AUDIO_CONTENTION_RETRIES)
  end

  it 'sends the deterministic fallback and skips the AI call for audio-only failures' do
    resolved = BotRuntime::TranscriptionEnricher::Result.new(
      event: event.merge(attachments: [], message_content: ''),
      fallback_reasons: [:too_long], in_progress: false, forward_to_agent: false
    )
    allow(BotRuntime::TranscriptionEnricher).to receive(:enrich).with(event).and_return(resolved)
    expect(BotRuntime::AudioFallbackService).to receive(:deliver).with(event, reasons: [:too_long])
    expect(BotRuntime::Client).not_to receive(:new)

    described_class.new.perform(event)
  end

  it 'forwards a mixed message once and does not send a second direct fallback' do
    mixed_event = event.merge(message_content: 'Quero reservar', attachments: [
                                { url: 'https://media.invalid/image', file_type: 'image' }
                              ])
    resolved = BotRuntime::TranscriptionEnricher::Result.new(
      event: mixed_event.merge(response_notice: BotRuntime::TranscriptionEnricher::TOO_LONG_NOTICE),
      fallback_reasons: [:too_long], in_progress: false, forward_to_agent: true
    )
    allow(BotRuntime::TranscriptionEnricher).to receive(:enrich).with(event).and_return(resolved)
    client = instance_double(BotRuntime::Client, send_event: true)
    allow(BotRuntime::Client).to receive(:new).and_return(client)
    expect(BotRuntime::AudioFallbackService).not_to receive(:deliver)

    described_class.new.perform(event)

    expect(client).to have_received(:send_event).with(resolved.event).once
    expect(resolved.event[:message_content]).to eq('Quero reservar')
    expect(resolved.event[:response_notice]).to include('mais de 4 minutos')
  end

  it 'sends the event on a retry after the competing transcription has persisted' do
    resolved = BotRuntime::TranscriptionEnricher::Result.new(
      event: event.merge(
        message_content: '[Transcrição do áudio]: Oi',
        attachments: []
      ),
      fallback_reasons: [], in_progress: false, forward_to_agent: true
    )
    allow(BotRuntime::TranscriptionEnricher).to receive(:enrich).with(event).and_return(resolved)
    client = instance_double(BotRuntime::Client, send_event: true)
    allow(BotRuntime::Client).to receive(:new).and_return(client)

    described_class.new.perform(event, 1)

    expect(client).to have_received(:send_event).with(resolved.event).once
  end
end
