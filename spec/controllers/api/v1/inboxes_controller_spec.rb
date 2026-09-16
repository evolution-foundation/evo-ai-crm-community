# frozen_string_literal: true

require 'rails_helper'

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
    let(:user) { User.create!(email: "inboxes-destroy-spec-#{SecureRandom.hex(4)}@example.com", name: 'Spec User') }
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

    before do
      Current.user = user
      Current.service_authenticated = true
      Current.authentication_method = 'service_token'

      allow(controller).to receive(:authenticate_request!).and_return(true)
      allow(controller).to receive(:authorize).and_return(true)
      allow(controller).to receive(:pundit_user).and_return({ user: user, account_user: nil })
    end

    after { Current.reset }

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
