# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::Providers::EvolutionService do
  let(:provider_config) do
    {
      'api_url' => 'https://evo.example.com',
      'admin_token' => 'test-token',
      'instance_name' => 'test-instance'
    }
  end
  let(:whatsapp_channel) { instance_double(Channel::Whatsapp, provider_config: provider_config) }
  let(:service) { described_class.new(whatsapp_channel: whatsapp_channel) }
  let(:phone_number) { '+5511999999999' }
  let(:success_response) do
    instance_double(
      HTTParty::Response,
      success?: true,
      parsed_response: { 'key' => { 'id' => 'msg-id-123' } }
    )
  end

  def attachment_double(file_type: 'image', name: "f.#{file_type}")
    file_double = instance_double('AttachmentFile', filename: double(to_s: name), attached?: false)
    instance_double('Attachment', file_type: file_type, file: file_double,
                                  file_url: "https://s3.example.com/#{name}")
  end

  describe '#fetch_profile_picture_url' do
    it 'POSTs the phone number to /chat/fetchProfilePictureUrl/{instance} and returns the URL' do
      response = instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: { 'profilePictureUrl' => 'https://cdn.example.com/p.jpg' }
      )
      allow(HTTParty).to receive(:post).and_return(response)

      url = service.fetch_profile_picture_url(phone_number)

      expect(url).to eq('https://cdn.example.com/p.jpg')
      expect(HTTParty).to have_received(:post) do |request_url, opts|
        expect(request_url).to eq('https://evo.example.com/chat/fetchProfilePictureUrl/test-instance')
        expect(JSON.parse(opts[:body])).to eq('number' => '5511999999999')
        expect(opts[:headers]['apikey']).to eq('test-token')
      end
    end

    it 'falls back to nested data.profilePictureUrl shape' do
      response = instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: { 'data' => { 'profilePictureUrl' => 'https://cdn.example.com/nested.jpg' } }
      )
      allow(HTTParty).to receive(:post).and_return(response)

      expect(service.fetch_profile_picture_url(phone_number)).to eq('https://cdn.example.com/nested.jpg')
    end

    it 'returns nil and logs when the upstream call fails' do
      response = instance_double(HTTParty::Response, success?: false, code: 502)
      allow(HTTParty).to receive(:post).and_return(response)

      expect(service.fetch_profile_picture_url(phone_number)).to be_nil
    end

    it 'returns nil when 200 OK body carries an error key' do
      response = instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: { 'error' => 'instance_disconnected', 'message' => 'instance not connected' }
      )
      allow(HTTParty).to receive(:post).and_return(response)
      allow(Rails.logger).to receive(:warn)

      expect(service.fetch_profile_picture_url(phone_number)).to be_nil
      expect(Rails.logger).to have_received(:warn).with(/200 OK with error body/)
    end

    it 'returns nil and rescues network errors' do
      allow(HTTParty).to receive(:post).and_raise(SocketError, 'connection refused')

      expect { service.fetch_profile_picture_url(phone_number) }.not_to raise_error
      expect(service.fetch_profile_picture_url(phone_number)).to be_nil
    end

    it 'returns nil for blank input without hitting the network' do
      expect(HTTParty).not_to receive(:post)
      expect(service.fetch_profile_picture_url('')).to be_nil
      expect(service.fetch_profile_picture_url(nil)).to be_nil
    end
  end

  describe '#check_number_exists?' do
    it 'POSTs to /chat/whatsappNumbers/{instance} and returns true when the number exists' do
      response = instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: [{ 'exists' => true, 'jid' => '5511999999999@s.whatsapp.net', 'number' => '5511999999999' }]
      )
      allow(HTTParty).to receive(:post).and_return(response)

      expect(service.check_number_exists?(phone_number)).to eq(true)
      expect(HTTParty).to have_received(:post) do |request_url, opts|
        expect(request_url).to eq('https://evo.example.com/chat/whatsappNumbers/test-instance')
        expect(JSON.parse(opts[:body])).to eq('numbers' => ['5511999999999'])
      end
    end

    it 'returns false when Evolution reports the number does not exist' do
      response = instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: [{ 'exists' => false, 'jid' => '5511999999999@s.whatsapp.net', 'number' => '5511999999999' }]
      )
      allow(HTTParty).to receive(:post).and_return(response)

      expect(service.check_number_exists?(phone_number)).to eq(false)
    end

    it 'returns nil when the upstream call fails, without raising' do
      response = instance_double(HTTParty::Response, success?: false, code: 500)
      allow(HTTParty).to receive(:post).and_return(response)

      expect(service.check_number_exists?(phone_number)).to be_nil
    end

    it 'returns nil and rescues network errors' do
      allow(HTTParty).to receive(:post).and_raise(SocketError, 'connection refused')

      expect { service.check_number_exists?(phone_number) }.not_to raise_error
      expect(service.check_number_exists?(phone_number)).to be_nil
    end

    it 'returns nil for blank input without hitting the network' do
      expect(HTTParty).not_to receive(:post)
      expect(service.check_number_exists?('')).to be_nil
      expect(service.check_number_exists?(nil)).to be_nil
    end
  end

  describe '#send_text_message (HTML to WhatsApp formatting)' do
    it 'converts bold HTML to WhatsApp bold' do
      message = instance_double('Message', content: '<strong>Hello</strong> World', attachments: double(present?: false), content_type: 'text')

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to eq('*Hello* World')
      end
    end

    it 'converts italic HTML to WhatsApp italic' do
      message = instance_double('Message', content: '<em>italic</em> text', attachments: double(present?: false), content_type: 'text')

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to eq('_italic_ text')
      end
    end

    it 'converts code HTML to WhatsApp monospace' do
      message = instance_double('Message', content: 'use <code>method()</code> here', attachments: double(present?: false), content_type: 'text')

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to eq('use `method()` here')
      end
    end

    it 'converts mixed formatting correctly' do
      message = instance_double('Message',
                                content: '<p><strong>Title</strong></p><p>Some <em>italic</em> and <code>code</code></p>',
                                attachments: double(present?: false), content_type: 'text')

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to include('*Title*')
        expect(body['text']).to include('_italic_')
        expect(body['text']).to include('`code`')
        expect(body['text']).not_to match(/<[^>]+>/)
      end
    end

    it 'preserves plain text content unchanged' do
      message = instance_double('Message', content: 'Hello World', attachments: double(present?: false), content_type: 'text')

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to eq('Hello World')
      end
    end

    it 'converts <br> tags to newlines' do
      message = instance_double('Message', content: 'Line 1<br>Line 2<br/>Line 3', attachments: double(present?: false), content_type: 'text')

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to include("Line 1\nLine 2\nLine 3")
      end
    end

    it 'converts <p> blocks to double newlines' do
      message = instance_double('Message', content: '<p>Paragraph 1</p><p>Paragraph 2</p>', attachments: double(present?: false), content_type: 'text')

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to include("Paragraph 1\n\nParagraph 2")
      end
    end

    it 'converts list items to dashes' do
      message = instance_double('Message',
                                content: '<ul><li>Item 1</li><li>Item 2</li></ul>',
                                attachments: double(present?: false), content_type: 'text')

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to include('- Item 1')
        expect(body['text']).to include('- Item 2')
      end
    end

    it 'strips HTML-only content to empty string' do
      message = instance_double('Message', content: '<p></p>', attachments: double(present?: false), content_type: 'text')

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to eq('')
      end
    end

    it 'handles string message (template fallback)' do
      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send(:send_text_message, phone_number, '<b>bold template</b>')

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to eq('*bold template*')
      end
    end
  end

  describe '#send_media_message (caption formatting)' do
    let(:attachment) { attachment_double(name: 'photo.jpg') }

    it 'converts HTML in caption to WhatsApp formatting' do
      message = instance_double('Message', content: '<p>Check this <b>image</b></p>',
                                           attachments: [attachment])

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['caption']).to include('*image*')
        expect(body['caption']).not_to match(/<[^>]+>/)
      end
    end
  end

  describe '#send_attachment_message (multiple attachments)' do
    it 'sends every attachment as its own Evolution API call, not just the first' do
      first_attachment = attachment_double(name: 'one.jpg')
      second_attachment = attachment_double(name: 'two.jpg')
      message = instance_double('Message', content: 'caption', attachments: [first_attachment, second_attachment])

      sent_filenames = []
      allow(HTTParty).to receive(:post) do |_url, opts|
        sent_filenames << JSON.parse(opts[:body])['fileName']
        success_response
      end

      service.send_message(phone_number, message)

      expect(sent_filenames).to contain_exactly('one.jpg', 'two.jpg')
    end
  end

  describe '#send_media_message (mediatype mapping — EVO-1940)' do
    def send_attachment_of(file_type)
      message = instance_double('Message', content: 'caption', attachments: [attachment_double(file_type: file_type)])
      allow(HTTParty).to receive(:post).and_return(success_response)
      service.send_message(phone_number, message)
    end

    it "maps a 'file' attachment (PDF/Word) to mediatype 'document'" do
      send_attachment_of('file')

      expect(HTTParty).to have_received(:post) do |_url, opts|
        expect(JSON.parse(opts[:body])['mediatype']).to eq('document')
      end
    end

    it "keeps 'image' as mediatype 'image' (no regression)" do
      send_attachment_of('image')

      expect(HTTParty).to have_received(:post) do |_url, opts|
        expect(JSON.parse(opts[:body])['mediatype']).to eq('image')
      end
    end

    it "keeps 'video' as mediatype 'video' (no regression)" do
      send_attachment_of('video')

      expect(HTTParty).to have_received(:post) do |_url, opts|
        expect(JSON.parse(opts[:body])['mediatype']).to eq('video')
      end
    end

    it 'maps the full enum to canonical Evolution API media types' do
      expect(service.send(:map_file_type_to_evolution_media_type, 'file')).to eq('document')
      expect(service.send(:map_file_type_to_evolution_media_type, 'image')).to eq('image')
      expect(service.send(:map_file_type_to_evolution_media_type, 'audio')).to eq('audio')
      expect(service.send(:map_file_type_to_evolution_media_type, 'video')).to eq('video')
      expect(service.send(:map_file_type_to_evolution_media_type, 'fallback')).to eq('document')
    end

    it 'returns false when the provider rejects the media send (surfaces failure to caller)' do
      message = instance_double('Message', content: 'caption',
                                           attachments: [attachment_double(file_type: 'file')])
      allow(HTTParty).to receive(:post).and_return(
        instance_double(HTTParty::Response, success?: false, code: 400, body: 'invalid mediatype')
      )

      expect(service.send_message(phone_number, message)).to be(false)
    end
  end

  describe '#toggle_typing_status' do
    # Evolution API's per-chat presence route is POST /chat/sendPresence/{instance}
    # (confirmed against evolution-api's chat.router.ts / SendPresenceDto) — not
    # /chat/setPresence/{instance}, which 404s. The DTO also requires `delay`.
    it 'POSTs composing presence to /chat/sendPresence/{instance} for typing_on' do
      response = instance_double(HTTParty::Response, success?: true, code: 200, body: '{}')
      expect(HTTParty).to receive(:post).with(
        'https://evo.example.com/chat/sendPresence/test-instance',
        hash_including(
          headers: { 'apikey' => 'test-token', 'Content-Type' => 'application/json' },
          body: { number: phone_number, presence: 'composing', delay: described_class::TYPING_PRESENCE_DELAY_MS }.to_json
        )
      ).and_return(response)

      expect(service.toggle_typing_status(phone_number, 'conversation.typing_on')).to eq(true)
    end

    it 'maps conversation.recording to the recording presence' do
      response = instance_double(HTTParty::Response, success?: true, code: 200, body: '{}')
      expect(HTTParty).to receive(:post).with(
        anything,
        hash_including(body: { number: phone_number, presence: 'recording', delay: described_class::TYPING_PRESENCE_DELAY_MS }.to_json)
      ).and_return(response)

      service.toggle_typing_status(phone_number, 'conversation.recording')
    end

    it 'maps conversation.typing_off to the paused presence' do
      response = instance_double(HTTParty::Response, success?: true, code: 200, body: '{}')
      expect(HTTParty).to receive(:post).with(
        anything,
        hash_including(body: { number: phone_number, presence: 'paused', delay: described_class::TYPING_PRESENCE_DELAY_MS }.to_json)
      ).and_return(response)

      service.toggle_typing_status(phone_number, 'conversation.typing_off')
    end

    it 'logs a warning and returns false on a non-2xx response' do
      response = instance_double(HTTParty::Response, success?: false, code: 404, body: 'Not Found')
      allow(HTTParty).to receive(:post).and_return(response)
      expect(Rails.logger).to receive(:warn).with(/non-2xx \(404\)/)

      expect(service.toggle_typing_status(phone_number, 'conversation.typing_on')).to eq(false)
    end

    it 'returns false and swallows the error when the HTTP call raises' do
      allow(HTTParty).to receive(:post).and_raise(Errno::ECONNREFUSED)

      expect(service.toggle_typing_status(phone_number, 'conversation.typing_on')).to eq(false)
    end
  end

  describe '#send_message — unsupported content (CRM-448)' do
    it 'flags the message is_unsupported and returns nil (the caller turns it into failed)' do
      message = instance_double(Message, attachments: [], content_type: 'text', content: nil)
      expect(message).to receive(:update!).with(is_unsupported: true)

      expect(service.send_message(phone_number, message)).to be_nil
    end

    # The production trigger is a content type this provider has no branch for.
    # `cards` is one: EvolutionGoService handles it, this service does not.
    it 'refuses a cards message, which only EvolutionGoService knows how to send' do
      message = instance_double(Message, attachments: [], content_type: 'cards', content: nil)
      expect(message).to receive(:update!).with(is_unsupported: true)

      expect(service.send_message(phone_number, message)).to be_nil
    end
  end
end
