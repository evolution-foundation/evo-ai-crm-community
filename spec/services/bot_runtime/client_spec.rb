# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe BotRuntime::Client do
  before do
    allow(BotRuntime::Config).to receive_messages(url: 'http://bot-runtime.internal:8080', secret: 'shh', timeout: 5)
  end

  describe '#send_presence_event' do
    it 'POSTs to /events/presence with the secret header' do
      stub_request(:post, 'http://bot-runtime.internal:8080/events/presence')
        .with(
          headers: { 'X-Bot-Runtime-Secret' => 'shh', 'Content-Type' => 'application/json' },
          body: { contact_id: 42, conversation_id: 7 }.to_json
        )
        .to_return(status: 202, body: '{"status":"accepted"}')

      expect { described_class.new.send_presence_event(contact_id: 42, conversation_id: 7) }.not_to raise_error
    end

    it 'raises RequestError on a non-2xx response' do
      stub_request(:post, 'http://bot-runtime.internal:8080/events/presence')
        .to_return(status: 500, body: 'boom')

      expect { described_class.new.send_presence_event(contact_id: 42, conversation_id: 7) }
        .to raise_error(BotRuntime::Client::RequestError, /500/)
    end
  end
end
