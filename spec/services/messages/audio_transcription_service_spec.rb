# frozen_string_literal: true

require 'rails_helper'

# Exercises the actual Whisper HTTP request being built — the sibling
# `audio_transcription_service_credential_spec.rb` only covers credential
# resolution and the transcription-enabled toggle, never the outgoing
# multipart request, so the model-override coverage lives here instead.
#
# `set_form(..., 'multipart/form-data')` assigns the encoded body to
# `body_stream`, not `body`, and WebMock does not expose or support matching
# a multipart body at all. So instead of WebMock, this stubs `Net::HTTP#request`
# directly to capture the real `Net::HTTP::Post` object built by the service —
# the same "double the raw HTTP call" style `compression_service_spec.rb`
# already uses for its unparseable-JSON example.
RSpec.describe Messages::AudioTranscriptionService do
  let(:attached_file) { instance_double(ActiveStorage::Attached::One, attached?: true) }
  let(:attachment) { instance_double(Attachment, id: 1, file: attached_file, extension: 'ogg') }
  let(:service) { described_class.new(attachment: attachment) }
  let(:audio_file) do
    file = Tempfile.new(['audio', '.ogg'])
    file.binmode
    file.write('fake-audio-bytes')
    file.rewind
    file
  end

  after { audio_file.close! }

  # `set_form(form_data, 'multipart/form-data')` stores the field array as-is
  # in `@body_data` and only encodes it into `body_stream` when the request is
  # actually sent over a socket — which never happens here, since `Net::HTTP#request`
  # itself is stubbed. Reading the field array directly is simpler and more
  # robust than parsing an encoded multipart body.
  def sent_model(request)
    request.instance_variable_get(:@body_data).assoc('model')&.last
  end

  # Doubles the raw HTTP call and hands back the `Net::HTTP::Post` the service
  # built, so the spec can inspect what it actually sent.
  def stub_whisper_request
    captured_request = nil
    response = instance_double(Net::HTTPOK, code: '200', body: { text: 'hello world' }.to_json)
    allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
    allow_any_instance_of(Net::HTTP).to receive(:request) do |_http, request|
      captured_request = request
      response
    end
    -> { captured_request }
  end

  describe '#call_openai_whisper_api uses the configured model override' do
    before do
      allow(service).to receive(:credential_endpoint)
        .and_return(Ai::CredentialResolver::Endpoint.new(key: 'sk-test-key', base_url: nil))
      allow(service).to receive(:detect_language).and_return(nil)
      allow(GlobalConfigService).to receive(:load)
        .with('OPENAI_API_URL', 'https://api.openai.com/v1').and_return('https://api.openai.com/v1')
    end

    it 'sends the OPENAI_AUDIO_TRANSCRIPTION_MODEL override to the Whisper endpoint' do
      allow(GlobalConfigService).to receive(:load)
        .with('OPENAI_AUDIO_TRANSCRIPTION_MODEL', 'whisper-1').and_return('whisper-2')
      captured_request = stub_whisper_request

      result = service.send(:call_openai_whisper_api, 'sk-test-key', audio_file)

      expect(result).to eq('text' => 'hello world')
      expect(sent_model(captured_request.call)).to eq('whisper-2')
    end

    it 'falls back to whisper-1 when nothing is configured' do
      allow(GlobalConfigService).to receive(:load)
        .with('OPENAI_AUDIO_TRANSCRIPTION_MODEL', 'whisper-1').and_return('whisper-1')
      captured_request = stub_whisper_request

      service.send(:call_openai_whisper_api, 'sk-test-key', audio_file)

      expect(sent_model(captured_request.call)).to eq('whisper-1')
    end
  end
end
