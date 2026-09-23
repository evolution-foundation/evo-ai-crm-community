require 'rails_helper'
require 'webmock/rspec'

RSpec.describe 'Webhooks::BotRuntime#presence', type: :request do
  let(:secret) { 'test-secret' }
  let!(:channel) do
    # Channel::Whatsapp#validate_provider_config issues a real HTTP health
    # check for the evolution provider (see
    # Whatsapp::Providers::EvolutionService#validate_provider_config?).
    # Stub it so channel creation succeeds under WebMock, same pattern as
    # spec/models/channel/whatsapp_spec.rb.
    stub_request(:get, 'https://evo.example.com/').to_return(status: 200, body: '{"status":200}')

    Channel::Whatsapp.create!(
      provider: 'evolution',
      phone_number: '+5511999999999',
      provider_config: { 'api_url' => 'https://evo.example.com', 'admin_token' => 'tok', 'instance_name' => 'inst' }
    )
  end
  let!(:inbox) { Inbox.create!(name: "Presence Webhook Spec Inbox #{SecureRandom.hex(2)}", channel: channel) }
  let!(:contact) { Contact.create!(name: 'Lead', phone_number: '+5511999999999') }
  # source_id must satisfy ContactInbox's whatsapp-inbox format validation
  # (digits, optionally +-prefixed) -- SecureRandom.hex(4) (used elsewhere for
  # non-whatsapp inboxes, e.g. spec/builders/conversation_builder_spec.rb) can
  # contain a-f letters and fails that check here.
  let!(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: '5511999999999') }
  let!(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  before do
    allow(BotRuntime::Config).to receive(:secret).and_return(secret)
  end

  def post_presence(display_id, typing_status:, headers: { 'X-Bot-Runtime-Secret' => secret })
    post "/webhooks/bot_runtime/presence/#{display_id}",
         params: { typing_status: typing_status }.to_json,
         headers: headers.merge('Content-Type' => 'application/json')
  end

  it 'rejects requests without the shared secret' do
    post_presence(conversation.display_id, typing_status: 'on', headers: {})
    expect(response).to have_http_status(:unauthorized)
  end

  it 'returns 404 when the conversation does not exist' do
    post_presence(999_999, typing_status: 'on')
    expect(response).to have_http_status(:not_found)
  end

  it 'maps typing_status "on" to CONVERSATION_TYPING_ON and forwards to the channel' do
    expect_any_instance_of(Channel::Whatsapp).to receive(:toggle_typing_status)
      .with('conversation.typing_on', conversation: conversation)

    post_presence(conversation.display_id, typing_status: 'on')
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to eq('status' => 'ok')
  end

  it 'maps typing_status "off" to CONVERSATION_TYPING_OFF' do
    expect_any_instance_of(Channel::Whatsapp).to receive(:toggle_typing_status)
      .with('conversation.typing_off', conversation: conversation)

    post_presence(conversation.display_id, typing_status: 'off')
    expect(response).to have_http_status(:ok)
  end

  it 'returns ok without calling the channel for an unknown typing_status' do
    expect_any_instance_of(Channel::Whatsapp).not_to receive(:toggle_typing_status)

    post_presence(conversation.display_id, typing_status: 'bogus')
    expect(response).to have_http_status(:ok)
  end
end
