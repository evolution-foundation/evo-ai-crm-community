# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BotRuntime::PresenceDelegationService do
  let(:conversation) { instance_double(Conversation, display_id: 7, contact_id: 'contact-1') }

  describe '#delegate' do
    context 'when Bot Runtime is enabled' do
      before { allow(BotRuntime::Config).to receive(:enabled?).and_return(true) }

      it 'enqueues SendPresenceEventJob with the stable contact id and display_id' do
        stable_id = BotRuntime::StableContactId.stable_contact_id('contact-1')

        expect(BotRuntime::SendPresenceEventJob).to receive(:perform_later)
          .with(contact_id: stable_id, conversation_id: 7)

        described_class.new(conversation).delegate
      end
    end

    context 'when Bot Runtime is disabled' do
      before { allow(BotRuntime::Config).to receive(:enabled?).and_return(false) }

      it 'does not enqueue anything' do
        expect(BotRuntime::SendPresenceEventJob).not_to receive(:perform_later)

        described_class.new(conversation).delegate
      end
    end
  end
end
