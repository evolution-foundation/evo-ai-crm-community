# frozen_string_literal: true

require 'rails_helper'

RSpec.shared_context 'with a service-authenticated user' do
  let(:user) { User.create!(email: "inboxes-spec-#{SecureRandom.hex(4)}@example.com", name: 'Spec User') }

  before do
    Current.user = user
    Current.service_authenticated = true
    Current.authentication_method = 'service_token'

    allow(controller).to receive(:authenticate_request!).and_return(true)
    allow(controller).to receive(:authorize).and_return(true)
    allow(controller).to receive(:pundit_user).and_return({ user: user, account_user: nil })
  end

  after { Current.reset }
end

RSpec.describe Api::V1::InboxesController, type: :controller do
  describe '#create' do
    it 'returns 422 when channel creation raises RecordNotSaved' do
      failed_channel = Channel::Telegram.new
      failed_channel.errors.add(:bot_token, 'error setting up the webhook: BACKEND_URL or FRONTEND_URL is missing')
      exception = ActiveRecord::RecordNotSaved.new('Failed to save the record', failed_channel)

      allow(controller).to receive(:create_channel).and_raise(exception)
      allow(controller).to receive(:error_response)
      allow(controller).to receive(:format_validation_errors).with(failed_channel.errors).and_return(
        { bot_token: ['error setting up the webhook: BACKEND_URL or FRONTEND_URL is missing'] }
      )

      controller.send(:create)

      expect(controller).to have_received(:error_response).with(
        ApiErrorCodes::VALIDATION_ERROR,
        'Bot token error setting up the webhook: BACKEND_URL or FRONTEND_URL is missing',
        details: { bot_token: ['error setting up the webhook: BACKEND_URL or FRONTEND_URL is missing'] },
        status: :unprocessable_entity
      )
    end
  end

  describe '#set_agent_bot' do
    let(:agent_bot) { instance_double(AgentBot) }
    let(:agent_bot_inbox) { instance_double(AgentBotInbox) }
    let(:existing_agent_bot_inbox) { nil }
    let(:inbox) { instance_double(Inbox, agent_bot_inbox: existing_agent_bot_inbox) }

    before do
      controller.instance_variable_set(:@agent_bot, agent_bot)
      controller.instance_variable_set(:@inbox, inbox)
      allow(controller).to receive(:params).and_return(ActionController::Parameters.new({}))
      allow(controller).to receive(:success_response)

      allow(agent_bot_inbox).to receive(:agent_bot=)
      allow(agent_bot_inbox).to receive(:allowed_conversation_statuses=)
      allow(agent_bot_inbox).to receive(:allowed_label_ids=)
      allow(agent_bot_inbox).to receive(:ignored_label_ids=)
      allow(agent_bot_inbox).to receive(:status=)
      allow(agent_bot_inbox).to receive(:save!)
    end

    context 'when inbox has no existing agent bot inbox' do
      it 'creates it and forces active status before save' do
        expect(AgentBotInbox).to receive(:new).with(inbox: inbox).and_return(agent_bot_inbox)
        expect(agent_bot_inbox).to receive(:status=).with(:active)
        expect(agent_bot_inbox).to receive(:save!)

        controller.send(:set_agent_bot)
      end
    end

    context 'when inbox already has an agent bot inbox' do
      let(:existing_agent_bot_inbox) { agent_bot_inbox }

      it 'reuses it and keeps active status before save' do
        expect(AgentBotInbox).not_to receive(:new)
        expect(agent_bot_inbox).to receive(:status=).with(:active)
        expect(agent_bot_inbox).to receive(:save!)

        controller.send(:set_agent_bot)
      end
    end
  end

  describe 'DELETE #destroy' do
    include_context 'with a service-authenticated user'

    let(:channel) { Channel::Api.create! }
    let!(:inbox) { Inbox.create!(name: "Destroy Spec Inbox #{SecureRandom.hex(2)}", channel: channel) }
    let(:contact) { Contact.create!(name: 'Destroy Spec Contact', email: "destroy-spec-#{SecureRandom.hex(4)}@example.com") }
    let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
    let!(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
    let!(:message) do
      Message.create!(
        inbox: inbox,
        conversation: conversation,
        message_type: :incoming,
        content: 'hello before archive'
      )
    end

    it 'archives the inbox instead of destroying it, keeping conversations and messages' do
      delete :destroy, params: { id: inbox.id }

      expect(response).to have_http_status(:ok)
      expect(inbox.reload.archived_at).to be_present
      expect(Conversation.exists?(conversation.id)).to be true
      expect(Message.exists?(message.id)).to be true
    end

    it 'does not enqueue DeleteObjectJob' do
      expect(DeleteObjectJob).not_to receive(:perform_later)

      delete :destroy, params: { id: inbox.id }
    end

    it 'keeps the response shape unchanged' do
      delete :destroy, params: { id: inbox.id }

      body = response.parsed_body
      expect(body.dig('data', 'id')).to eq(inbox.id)
      expect(body['message']).to eq(I18n.t('messages.inbox_deletetion_response'))
    end
  end

  describe 'POST #reactivate' do
    include_context 'with a service-authenticated user'

    let(:channel) { Channel::Api.create! }
    let!(:inbox) { Inbox.create!(name: "Reactivate Spec Inbox #{SecureRandom.hex(2)}", channel: channel) }

    context 'when the inbox is archived' do
      before { inbox.update!(archived_at: Time.current) }

      it 'clears archived_at and returns 200' do
        post :reactivate, params: { id: inbox.id }

        expect(response).to have_http_status(:ok)
        expect(inbox.reload.archived_at).to be_nil
      end
    end

    context 'when the inbox is not archived' do
      it 'returns 422' do
        post :reactivate, params: { id: inbox.id }

        expect(response).to have_http_status(:unprocessable_entity)
      end
    end
  end

  describe 'GET #archived_whatsapp_match' do
    include_context 'with a service-authenticated user'

    # hub_managed? (provider_config['evolution_hub'] present) short-circuits the
    # credential probe in #validate_provider_config, so create! doesn't need a
    # real Meta/Evolution API to succeed (mirrors evolution_hub_channel_cleanup_spec.rb).
    let(:channel) do
      Channel::Whatsapp.create!(
        phone_number: '+5511999999999',
        provider: 'whatsapp_cloud',
        provider_config: { 'api_key' => '', 'phone_number_id' => '', 'evolution_hub' => { 'status' => 'active' } }
      )
    end
    let!(:inbox) { Inbox.create!(name: "Archived Match Spec Inbox #{SecureRandom.hex(2)}", channel: channel) }

    context 'when an archived channel matches the phone number' do
      before { inbox.update!(archived_at: Time.current) }

      it 'returns the archived inbox id' do
        get :archived_whatsapp_match, params: { phone_number: '+5511999999999' }

        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body.dig('data', 'inbox_id')).to eq(inbox.id)
      end
    end

    context 'when the matching channel is not archived' do
      it 'returns null data' do
        get :archived_whatsapp_match, params: { phone_number: '+5511999999999' }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['data']).to be_nil
      end
    end

    context 'when no channel matches the phone number' do
      it 'returns null data' do
        get :archived_whatsapp_match, params: { phone_number: '+5599888887777' }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['data']).to be_nil
      end
    end

    # Regression: the stored phone_number and the one the phone input sends on
    # a later create attempt are not guaranteed to be formatted identically
    # (spaces, dashes, missing '+') — an exact string match silently misses the
    # archived channel, so the user falls through to plain create and hits the
    # DB's raw uniqueness error instead of the reactivate/replace flow.
    context 'when the phone number matches only after stripping formatting' do
      before { inbox.update!(archived_at: Time.current) }

      it 'still finds the archived inbox for a differently formatted but equivalent number' do
        get :archived_whatsapp_match, params: { phone_number: '+55 (11) 99999-9999' }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.dig('data', 'inbox_id')).to eq(inbox.id)
      end
    end
  end

  describe 'POST #replace_archived_channel' do
    include_context 'with a service-authenticated user'

    # hub_managed? (provider_config['evolution_hub'] present) short-circuits the
    # credential probe in #validate_provider_config for both the old and new
    # channel, so create!/destroy! don't need a real Meta/Evolution API.
    let(:old_channel) do
      Channel::Whatsapp.create!(
        phone_number: '+5511999999999',
        provider: 'whatsapp_cloud',
        provider_config: { 'api_key' => '', 'phone_number_id' => '', 'evolution_hub' => { 'status' => 'active' } }
      )
    end
    let!(:inbox) { Inbox.create!(name: "Replace Channel Spec Inbox #{SecureRandom.hex(2)}", channel: old_channel) }
    let(:new_channel_params) do
      { provider: 'evolution', provider_config: { 'evolution_hub' => { 'status' => 'active' } } }
    end

    context 'when the inbox is archived' do
      before { inbox.update!(archived_at: Time.current) }

      it 'creates a new channel with the same phone number, re-points the inbox, and reactivates it' do
        old_channel_id = old_channel.id

        post :replace_archived_channel, params: { id: inbox.id, channel: new_channel_params }

        expect(response).to have_http_status(:ok)
        inbox.reload
        expect(inbox.archived_at).to be_nil
        new_channel = inbox.channel
        expect(new_channel.provider).to eq('evolution')
        expect(new_channel.phone_number).to eq('+5511999999999')
        expect(Channel::Whatsapp.exists?(old_channel_id)).to be false
      end

      it 'keeps conversations and messages attached to the same inbox' do
        contact = Contact.create!(name: 'Replace Spec Contact', phone_number: '+5511999999999')
        contact_inbox = ContactInbox.create!(inbox: inbox, contact: contact, source_id: '5511999999999')
        conversation = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
        message = Message.create!(inbox: inbox, conversation: conversation, message_type: :incoming, content: 'before replace')

        post :replace_archived_channel, params: { id: inbox.id, channel: new_channel_params }

        expect(Conversation.exists?(conversation.id)).to be true
        expect(Message.exists?(message.id)).to be true
        expect(conversation.reload.inbox_id).to eq(inbox.id)
      end

      it 'ignores a client-submitted phone_number and always reuses the archived channel\'s number' do
        post :replace_archived_channel, params: {
          id: inbox.id,
          channel: new_channel_params.merge(phone_number: '+5511000000000')
        }

        expect(inbox.reload.channel.phone_number).to eq('+5511999999999')
      end

      it 'rolls back and keeps the old channel intact when the new channel is invalid' do
        # evolution_hub bypass keeps validate_provider_config from making a real
        # HTTP call before the (separate) provider-inclusion validation is what
        # actually fails here.
        post :replace_archived_channel, params: {
          id: inbox.id,
          channel: { provider: 'not_a_real_provider', provider_config: { 'evolution_hub' => { 'status' => 'active' } } }
        }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(inbox.reload.archived_at).to be_present
        expect(Channel::Whatsapp.find(old_channel.id).phone_number).to eq('+5511999999999')
      end
    end

    context 'when the inbox is not archived' do
      it 'returns 422' do
        post :replace_archived_channel, params: { id: inbox.id, channel: new_channel_params }

        expect(response).to have_http_status(:unprocessable_entity)
      end
    end

    context 'when the inbox is not a WhatsApp inbox' do
      let(:api_channel) { Channel::Api.create! }
      let!(:api_inbox) { Inbox.create!(name: "Replace Channel Spec API Inbox #{SecureRandom.hex(2)}", channel: api_channel, archived_at: Time.current) }

      it 'returns 422' do
        post :replace_archived_channel, params: { id: api_inbox.id, channel: new_channel_params }

        expect(response).to have_http_status(:unprocessable_entity)
      end
    end
  end

  describe '#fetch_agent_bot' do
    let(:agent_bot) { instance_double(AgentBot) }

    before do
      allow(AgentBot).to receive(:find).with('bot-123').and_return(agent_bot)
    end

    context 'when the bot id is sent under :agent_bot (frontend)' do
      it 'resolves the agent bot' do
        allow(controller).to receive(:params).and_return(
          ActionController::Parameters.new(agent_bot: 'bot-123')
        )

        controller.send(:fetch_agent_bot)

        expect(controller.instance_variable_get(:@agent_bot)).to eq(agent_bot)
      end
    end

    context 'when the bot id is sent under :agent_bot_id (journeys / evo-flow)' do
      it 'resolves the agent bot so the binding persists (EVO-1900)' do
        allow(controller).to receive(:params).and_return(
          ActionController::Parameters.new(agent_bot_id: 'bot-123')
        )

        controller.send(:fetch_agent_bot)

        expect(controller.instance_variable_get(:@agent_bot)).to eq(agent_bot)
      end
    end

    context 'when no bot id is provided' do
      it 'leaves @agent_bot nil without hitting the database' do
        allow(controller).to receive(:params).and_return(
          ActionController::Parameters.new({})
        )
        expect(AgentBot).not_to receive(:find)

        controller.send(:fetch_agent_bot)

        expect(controller.instance_variable_get(:@agent_bot)).to be_nil
      end
    end
  end
end
