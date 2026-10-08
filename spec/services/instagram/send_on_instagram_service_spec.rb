# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# With the Evolution Hub on, every Instagram reply goes through the Hub's /meta proxy,
# which only accepts the channel token as a Bearer header and forwards the query to Meta
# untouched. Without the Hub the reply goes straight to Meta with the token in the query.
RSpec.describe Instagram::SendOnInstagramService do
  subject(:service) { described_class.new(message: message) }

  let(:hub_url) { 'https://hub.test' }
  let(:hub_meta) { { 'channel_id' => 'hub-ch-1', 'channel_token' => 'hub-channel-token', 'status' => 'active' } }
  let(:channel) do
    Channel::Instagram.new(id: SecureRandom.uuid, instagram_id: '17841400000000001', evolution_hub_meta: hub_meta,
                           expires_at: 30.days.from_now, updated_at: Time.current).tap do |record|
      record[:access_token] = stored_access_token
    end
  end
  let(:stored_access_token) { 'hub-managed-0123456789abcdef' }
  let(:attachments) { [] }
  let(:contact) { instance_double(Contact) }
  let(:inbox) { instance_double(Inbox, id: 7, channel: channel) }
  let(:conversation) { instance_double(Conversation, contact: contact, inbox: inbox) }
  let(:message) do
    instance_double(Message, conversation: conversation, content: 'Oi, tudo bem?', attachments: attachments,
                             update!: true, sender: nil)
  end
  let(:status_update) { instance_double(Messages::StatusUpdateService, perform: true) }

  before do
    allow(contact).to receive(:get_source_id).with(7).and_return('ig-scoped-user-1')
    allow(GlobalConfig).to receive(:get).and_return({})
    allow(Messages::StatusUpdateService).to receive(:new).and_return(status_update)
    allow(EvolutionExceptionTracker).to receive(:new).and_return(instance_double(EvolutionExceptionTracker, capture_exception: true))
  end

  def hub_on!
    allow(MetaBaseUrl).to receive_messages(enabled?: true, hub_url: hub_url)
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
    let(:stored_access_token) { 'IGAA-real-meta-token' }

    before { allow(MetaBaseUrl).to receive(:enabled?).and_return(false) }

    it 'goes straight to Meta with the token in the query and no Authorization header' do
      stub = stub_send(%r{\Ahttps://graph\.instagram\.com/v23\.0/17841400000000001/messages\?access_token=IGAA-real-meta-token\z})

      reply!

      expect(stub).to have_been_requested.once
      expect(a_request(:post, /graph\.instagram\.com/).with { |req| req.headers.key?('Authorization') }).not_to have_been_made
      expect(message).to have_received(:update!).with(source_id: 'mid.1')
    end
  end

  context 'with the Hub on and a channel the Hub manages' do
    before { hub_on! }

    it 'sends the channel token as a Bearer header and nothing in the query' do
      stub = stub_send("#{hub_url}/meta/17841400000000001/messages")
             .with(headers: { 'Authorization' => 'Bearer hub-channel-token' }) { |req| req.uri.query.nil? }

      reply!

      expect(stub).to have_been_requested.once
      expect(message).to have_received(:update!).with(source_id: 'mid.1')
    end

    it 'never sends the placeholder or encrypted access_token it stores' do
      ['hub-managed-0123456789abcdef', 'enc:v1:abc'].each do |stored|
        channel[:access_token] = stored
        WebMock.reset!
        stub_send(%r{\A#{hub_url}/meta/})

        reply!

        expect(a_request(:post, %r{\A#{hub_url}/meta/}).with(headers: { 'Authorization' => 'Bearer hub-channel-token' }))
          .to have_been_made.once
        expect(a_request(:post, /#{Regexp.escape(stored)}/)).not_to have_been_made
      end
    end

    # Bodies Meta never writes: none at all (an empty HTTParty::Response answers true
    # to nil?) or the ingress's HTML error page.
    [502, 401, 200].each do |status|
      it "fails the message when the proxy answers #{status} with an empty body" do
        stub_request(:post, "#{hub_url}/meta/17841400000000001/messages").to_return(status: status, body: '')

        reply!

        expect(Messages::StatusUpdateService).to have_received(:new).with(message, 'failed', "#{status} - unexpected response")
        expect(message).not_to have_received(:update!)
        expect(EvolutionExceptionTracker).not_to have_received(:new)
      end
    end

    it 'fails the message when the ingress answers with its HTML error page' do
      stub_request(:post, "#{hub_url}/meta/17841400000000001/messages")
        .to_return(status: 502, body: '<html><head><title>502 Bad Gateway</title></head></html>',
                   headers: { 'Content-Type' => 'text/html' })

      reply!

      expect(Messages::StatusUpdateService).to have_received(:new).with(message, 'failed', '502 - unexpected response')
      expect(EvolutionExceptionTracker).not_to have_received(:new)
    end

    context 'with an attachment' do
      let(:attachments) do
        [instance_double(Attachment, file_type: 'image', download_url: 'https://cdn.test/photo.png')]
      end

      it 'authenticates the attachment send the same way' do
        stub = stub_send("#{hub_url}/meta/17841400000000001/messages")
               .with(headers: { 'Authorization' => 'Bearer hub-channel-token' }) { |req| req.uri.query.nil? }

        reply!

        expect(stub).to have_been_requested.twice
      end
    end
  end

  context 'with the Hub on and a channel connected straight to Meta before the Hub' do
    let(:hub_meta) { {} }
    let(:stored_access_token) { 'IGAA-real-meta-token' }

    before { hub_on! }

    # The proxy only authenticates Hub channels, so this channel's own Meta token
    # would only be refused there after leaving the CRM.
    it 'fails the message without sending its Meta token anywhere' do
      reply!

      expect(a_request(:any, /.*/)).not_to have_been_made
      expect(Messages::StatusUpdateService).to have_received(:new)
        .with(message, 'failed', described_class::HUB_CHANNEL_NOT_LINKED)
      expect(EvolutionExceptionTracker).not_to have_received(:new)
    end
  end

  context 'with the Hub on and a managed channel that lost its channel token' do
    let(:hub_meta) { { 'channel_id' => 'hub-ch-1', 'status' => 'active' } }

    before { hub_on! }

    it 'recovers the token from the Hub and sends with it' do
      allow(EvolutionHub::ChannelReconciler).to receive(:heal_from_hub) do |record|
        record.evolution_hub_meta = record.evolution_hub_meta.merge('channel_token' => 'recovered-token')
        true
      end
      stub = stub_send("#{hub_url}/meta/17841400000000001/messages")
             .with(headers: { 'Authorization' => 'Bearer recovered-token' })

      reply!

      expect(stub).to have_been_requested.once
    end

    it 'marks the message failed without calling the proxy when the Hub has no token either' do
      allow(EvolutionHub::ChannelReconciler).to receive(:heal_from_hub).and_return(false)

      reply!

      expect(a_request(:any, /.*/)).not_to have_been_made
      expect(Messages::StatusUpdateService).to have_received(:new)
        .with(message, 'failed', described_class::HUB_TOKEN_MISSING)
      expect(EvolutionExceptionTracker).not_to have_received(:new)
    end
  end
end
