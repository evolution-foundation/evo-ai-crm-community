# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BotRuntime::SendEventJob do
  let(:event) { { conversation_id: 7, agent_bot_id: 'bot-1', api_key: 'bot-secret-key', message_content: 'hi' } }
  let(:log) { StringIO.new }

  around do |example|
    original = ActiveJob::Base.logger
    ActiveJob::Base.logger = ActiveSupport::TaggedLogging.new(Logger.new(log))
    example.run
  ensure
    ActiveJob::Base.logger = original
  end

  it 'keeps the event out of the job log' do
    client = instance_double(BotRuntime::Client, send_event: true)
    allow(BotRuntime::Client).to receive(:new).and_return(client)

    described_class.perform_later(event)
    described_class.perform_now(event)

    expect(client).to have_received(:send_event).with(event)
    expect(log.string).to include('BotRuntime::SendEventJob')
    expect(log.string).not_to include('bot-secret-key')
  end
end
