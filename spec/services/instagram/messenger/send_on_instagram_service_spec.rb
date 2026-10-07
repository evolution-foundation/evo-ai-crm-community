# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# Instagram replies sent through a Facebook Page follow the same Hub contract as the
# Instagram channel: the channel token as a Bearer header and nothing in the query.
RSpec.describe Instagram::Messenger::SendOnInstagramService do
  subject(:service) { described_class.new(message: message) }

  let(:hub_url) { 'https://hub.test' }
  let(:hub_meta) { { 'channel_id' => 'hub-fb-1', 'channel_token' => 'hub-page-token', 'status' => 'active' } }
  let(:channel) do
    Channel::FacebookPage.new(id: SecureRandom.uuid, page_id: 'page-1', page_access_token: 'EAA-page-token',
                              evolution_hub_meta: hub_meta)
  end
  let(:contact) { instance_double(Contact) }
  let(:inbox) { instance_double(Inbox, id: 7, channel: channel) }
  let(:conversation) { instance_double(Conversation, contact: contact, inbox: inbox) }
  let(:message) do
    instance_double(Message, conversation: conversation, content: 'Oi, tudo bem?', attachments: [], update!: true,
                             sender: nil)
  end
  let(:status_update) { instance_double(Messages::StatusUpdateService, perform: true) }

  before do
    allow(contact).to receive(:get_source_id).with(7).and_return('ig-scoped-user-1')
    allow(GlobalConfig).to receive(:get).and_return({})
    allow(Messages::StatusUpdateService).to receive(:new).and_return(status_update)
  end

  def stub_send(url)
    stub_request(:post, url).to_return(status: 200, body: { message_id: 'mid.1' }.to_json,
                                       headers: { 'Content-Type' => 'application/json' })
  end

  def reply!
    service.send(:perform_reply)
  end

  context 'with the Hub off' do
    let(:hub_meta) { {} }

    before do
      allow(MetaBaseUrl).to receive(:enabled?).and_return(false)
      allow(GlobalConfigService).to receive(:load).and_call_original
      allow(GlobalConfigService).to receive(:load).with('FB_APP_SECRET', '').and_return('app-secret')
    end

    it 'goes straight to Meta with the page token and its proof in the query' do
      proof = Facebook::Messenger::Configuration::AppSecretProofCalculator.call('app-secret', 'EAA-page-token')
      stub = stub_send('https://graph.facebook.com/v23.0/me/messages')
             .with(query: { 'access_token' => 'EAA-page-token', 'appsecret_proof' => proof })

      reply!

      expect(stub).to have_been_requested.once
      expect(a_request(:post, /graph\.facebook\.com/).with { |req| req.headers.key?('Authorization') }).not_to have_been_made
      expect(message).to have_received(:update!).with(source_id: 'mid.1')
    end
  end

  context 'with the Hub on and a page the Hub manages' do
    before { allow(MetaBaseUrl).to receive_messages(enabled?: true, hub_url: hub_url) }

    it 'sends the channel token as a Bearer header and nothing in the query' do
      stub = stub_send("#{hub_url}/meta/me/messages")
             .with(headers: { 'Authorization' => 'Bearer hub-page-token' }) { |req| req.uri.query.nil? }

      reply!

      expect(stub).to have_been_requested.once
      expect(message).to have_received(:update!).with(source_id: 'mid.1')
    end
  end

  context 'with the Hub on and a page connected straight to Meta' do
    let(:hub_meta) { {} }

    before { allow(MetaBaseUrl).to receive_messages(enabled?: true, hub_url: hub_url) }

    it 'fails the message without sending its page token anywhere' do
      reply!

      expect(a_request(:any, /.*/)).not_to have_been_made
      expect(Messages::StatusUpdateService).to have_received(:new)
        .with(message, 'failed', described_class::HUB_CHANNEL_NOT_LINKED)
    end
  end
end
