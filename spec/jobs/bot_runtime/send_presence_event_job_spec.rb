# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BotRuntime::SendPresenceEventJob do
  it 'delegates to BotRuntime::Client#send_presence_event' do
    client = instance_double(BotRuntime::Client)
    allow(BotRuntime::Client).to receive(:new).and_return(client)
    expect(client).to receive(:send_presence_event).with({ contact_id: 1, conversation_id: 2 })

    described_class.new.perform(contact_id: 1, conversation_id: 2)
  end

  it 'swallows a client failure instead of raising (best-effort)' do
    client = instance_double(BotRuntime::Client)
    allow(BotRuntime::Client).to receive(:new).and_return(client)
    allow(client).to receive(:send_presence_event).and_raise(BotRuntime::Client::RequestError, 'boom')

    expect { described_class.new.perform(contact_id: 1, conversation_id: 2) }.not_to raise_error
  end
end
