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
end
