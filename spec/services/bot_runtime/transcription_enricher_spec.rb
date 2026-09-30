# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BotRuntime::TranscriptionEnricher do
  let(:audio_attachment) { instance_double(Attachment, audio?: true, meta: {}, id: 'attachment-123') }
  let(:image_attachment) { instance_double(Attachment, audio?: false, meta: {}) }
  let(:message) { instance_double(Message, attachments: [audio_attachment, image_attachment]) }
  let(:relation) { instance_double(ActiveRecord::Relation, find_by: message) }
  let(:event) do
    {
      message_id: 'message-123',
      message_content: 'Pode ouvir?',
      attachments: [
        { url: 'https://media.invalid/audio', file_type: 'audio' },
        { url: 'https://media.invalid/image', file_type: 'image' }
      ]
    }
  end

  before do
    allow(Message).to receive(:includes).with(:attachments).and_return(relation)
  end

  it 'adds the persisted transcript to the agent text and removes only raw audio' do
    allow(audio_attachment).to receive(:meta).and_return('transcribed_text' => 'Quero reservar para amanhã.')

    result = described_class.enrich(event)

    expect(result.event[:message_content]).to include('Pode ouvir?', 'Quero reservar para amanhã.')
    expect(result.event[:message_content]).to include(described_class::TRANSCRIPT_LABEL)
    expect(result.event[:attachments]).to eq([{ url: 'https://media.invalid/image', file_type: 'image' }])
  end

  it 'transcribes once and persists through the shared transcription service' do
    allow(audio_attachment).to receive(:meta).and_return({})
    service = instance_double(Messages::AudioTranscriptionService)
    allow(Messages::AudioTranscriptionService).to receive(:new).with(attachment: audio_attachment).and_return(service)
    expect(service).to receive(:perform).with(for_agent: true).and_return(success: true, transcribed_text: 'Olá')

    expect(described_class.enrich(event).event[:message_content]).to include(
      "#{described_class::TRANSCRIPT_LABEL}: Olá"
    )
  end

  it 'fails closed when transcription is unavailable without forwarding audio' do
    allow(audio_attachment).to receive(:meta).and_return({})
    service = instance_double(Messages::AudioTranscriptionService)
    allow(Messages::AudioTranscriptionService).to receive(:new).with(attachment: audio_attachment).and_return(service)
    allow(service).to receive(:perform).with(for_agent: true).and_return(
      error: 'Audio transcription failed', status: :provider_failed
    )
    relation = instance_double(ActiveRecord::Relation, update_all: 1)
    allow(Attachment).to receive(:where).with(id: audio_attachment.id).and_return(relation)
    allow(relation).to receive(:where).and_return(relation)

    result = described_class.enrich(event)

    expect(result.event[:message_content]).to eq('Pode ouvir?')
    expect(result.event[:response_notice]).to eq(described_class::UNAVAILABLE_NOTICE)
    expect(result.fallback_reasons).to eq([:unavailable])
    expect(result.event[:attachments]).to eq([{ url: 'https://media.invalid/image', file_type: 'image' }])
    expect(relation).to have_received(:update_all)
  end

  it 'fails closed when the event has audio but no persisted audio attachment can be resolved' do
    non_audio_message = instance_double(Message, attachments: [image_attachment])
    allow(relation).to receive(:find_by).with(id: 'message-123').and_return(non_audio_message)
    expect(Messages::AudioTranscriptionService).not_to receive(:new)

    result = described_class.enrich(event)

    expect(result.event[:message_content]).to eq('Pode ouvir?')
    expect(result.event[:response_notice]).to eq(described_class::UNAVAILABLE_NOTICE)
    expect(result.fallback_reasons).to eq([:unavailable])
    expect(result.event[:attachments]).to eq([{ url: 'https://media.invalid/image', file_type: 'image' }])
    expect(result.forward_to_agent).to be(true)
  end

  it 'uses a specific fallback and avoids retranscribing audio over four minutes' do
    allow(audio_attachment).to receive(:meta).and_return({})
    service = instance_double(Messages::AudioTranscriptionService)
    allow(Messages::AudioTranscriptionService).to receive(:new).with(attachment: audio_attachment).and_return(service)
    allow(service).to receive(:perform).with(for_agent: true).and_return(
      error: 'Audio exceeds maximum duration', status: :too_long, max_duration_seconds: 240
    )
    expect(Attachment).not_to receive(:where)

    result = described_class.enrich(event)

    expect(result.event[:message_content]).to eq('Pode ouvir?')
    expect(result.event[:response_notice]).to eq(described_class::TOO_LONG_NOTICE)
    expect(result.fallback_reasons).to eq([:too_long])
    expect(result.event[:attachments]).to eq([{ url: 'https://media.invalid/image', file_type: 'image' }])
    expect(result.forward_to_agent).to be(true)
  end

  it 'routes an audio-only over-limit event to the deterministic CRM fallback' do
    audio_only_message = instance_double(Message, attachments: [audio_attachment])
    allow(relation).to receive(:find_by).with(id: 'message-123').and_return(audio_only_message)
    allow(audio_attachment).to receive(:meta).and_return(
      'audio_transcription_failure' => 'duration_exceeded'
    )
    audio_only_event = event.merge(message_content: '', attachments: [
                                     { url: 'https://media.invalid/audio', file_type: 'audio' }
                                   ])
    expect(Messages::AudioTranscriptionService).not_to receive(:new)

    result = described_class.enrich(audio_only_event)

    expect(result.fallback_reasons).to eq([:too_long])
    expect(result.forward_to_agent).to be(false)
    expect(result.event[:message_content]).to eq('')
    expect(result.event[:attachments]).to be_empty
  end

  it 'removes multiple audio payloads, keeps transcripts and emits one long-audio reason' do
    second_audio = instance_double(Attachment, audio?: true, id: 'attachment-456', meta: {
                                     'audio_transcription_failure' => 'duration_exceeded'
                                   })
    multi_audio_message = instance_double(Message, attachments: [audio_attachment, second_audio, image_attachment])
    allow(relation).to receive(:find_by).with(id: 'message-123').and_return(multi_audio_message)
    allow(audio_attachment).to receive(:meta).and_return('transcribed_text' => 'Quero reservar.')
    multi_audio_event = event.merge(attachments: event[:attachments] + [
      { url: 'https://media.invalid/audio-2', file_type: 'audio' }
    ])

    result = described_class.enrich(multi_audio_event)

    expect(result.event[:message_content]).to include('Pode ouvir?', 'Quero reservar.')
    expect(result.event[:response_notice]).to eq(described_class::TOO_LONG_NOTICE)
    expect(result.event[:attachments]).to eq([{ url: 'https://media.invalid/image', file_type: 'image' }])
    expect(result.fallback_reasons).to eq([:too_long])
  end

  it 'does not transcribe again during the retry backoff window' do
    allow(audio_attachment).to receive(:meta).and_return(
      'audio_transcription_retry_after' => 2.minutes.from_now.iso8601
    )

    expect(Messages::AudioTranscriptionService).not_to receive(:new)
    result = described_class.enrich(event)

    expect(result.event[:message_content]).to eq('Pode ouvir?')
    expect(result.fallback_reasons).to eq([:unavailable])
    expect(result.event[:attachments]).to eq([{ url: 'https://media.invalid/image', file_type: 'image' }])
    expect(result.event[:response_notice]).to eq(described_class::UNAVAILABLE_NOTICE)
  end

  it 'atomically preserves another worker lease and does not extend an active retry backoff' do
    attachment = Attachment.new(
      attachable_type: 'Message',
      attachable_id: SecureRandom.uuid,
      file_type: :audio,
      meta: {
        'audio_transcription_processing_until' => 1.minute.from_now.iso8601,
        'audio_transcription_retry_after' => 1.minute.from_now.iso8601
      }
    )
    attachment.save!(validate: false)

    described_class.allocate.send(:record_transcription_failure, attachment)

    expect(attachment.reload.meta['audio_transcription_processing_until']).to be_present
    retry_after = Time.zone.parse(attachment.meta['audio_transcription_retry_after'])
    expect(retry_after).to be_within(2.seconds).of(1.minute.from_now)
  ensure
    attachment&.destroy!
  end

  it 'keeps string-keyed event payloads string-keyed' do
    allow(audio_attachment).to receive(:meta).and_return('transcribed_text' => 'Oi')
    string_event = event.transform_keys(&:to_s)

    result = described_class.enrich(string_event)

    expect(result.event.keys).to all(be_a(String))
    expect(result.event['message_content']).to include('Oi')
    expect(result.event['attachments']).to eq([{ url: 'https://media.invalid/image', file_type: 'image' }])
    expect(result.event['response_notice']).to be_nil
  end

  it 'returns an in-progress state without recording a transcription failure' do
    allow(audio_attachment).to receive(:meta).and_return({})
    service = instance_double(Messages::AudioTranscriptionService)
    allow(Messages::AudioTranscriptionService).to receive(:new).with(attachment: audio_attachment).and_return(service)
    allow(service).to receive(:perform).with(for_agent: true).and_return(
      error: 'Transcription already in progress', status: :in_progress
    )
    expect(Attachment).not_to receive(:where)

    result = described_class.enrich(event)

    expect(result.in_progress).to be(true)
    expect(result.fallback_reasons).to be_empty
  end

  it 'prioritizes an active lease over an unexpired retry backoff' do
    allow(audio_attachment).to receive(:meta).and_return(
      'audio_transcription_processing_until' => 1.minute.from_now.iso8601,
      'audio_transcription_retry_after' => 2.minutes.from_now.iso8601
    )
    expect(Messages::AudioTranscriptionService).not_to receive(:new)
    expect(Attachment).not_to receive(:where)

    result = described_class.enrich(event)

    expect(result.in_progress).to be(true)
    expect(result.fallback_reasons).to be_empty
  end
end
