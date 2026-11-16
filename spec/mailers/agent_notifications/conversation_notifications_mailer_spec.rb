# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AgentNotifications::ConversationNotificationsMailer do
  let(:agent) { User.create!(name: 'Agente', email: %w[agente example.com].join('@')) }
  let(:channel) { Channel::Api.create! }
  let(:inbox) { Inbox.create!(name: 'Mail Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Cliente') }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:conversation_link) { "#{ENV.fetch('FRONTEND_URL', 'http://localhost:5173').chomp('/')}/conversations/#{conversation.id}" }

  around do |example|
    original = ActionMailer::Base.delivery_method
    ActionMailer::Base.delivery_method = :test
    example.run
  ensure
    ActionMailer::Base.delivery_method = original
  end

  before { allow_any_instance_of(described_class).to receive(:smtp_config_set_or_development?).and_return(true) }

  it 'links the assignment email to the conversation in the front' do
    mail = described_class.with({}).conversation_assignment(conversation, agent, nil).deliver_now

    expect(mail.to).to eq([agent.email])
    expect(mail.body.encoded).to include(conversation_link)
  end

  it 'links the creation email to the conversation in the front' do
    mail = described_class.with({}).conversation_creation(conversation, agent, nil).deliver_now

    expect(mail.body.encoded).to include(conversation_link)
  end
end
