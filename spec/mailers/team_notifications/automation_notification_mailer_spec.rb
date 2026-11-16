# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TeamNotifications::AutomationNotificationMailer do
  let(:agent) { User.create!(name: 'Agente', email: %w[time-agente example.com].join('@')) }
  let(:team) { Team.create!(name: 'Time de teste').tap { |t| TeamMember.create!(team: t, user: agent) } }
  let(:channel) { Channel::Api.create! }
  let(:inbox) { Inbox.create!(name: 'Team Mail Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Cliente') }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  around do |example|
    original = ActionMailer::Base.delivery_method
    ActionMailer::Base.delivery_method = :test
    example.run
  ensure
    ActionMailer::Base.delivery_method = original
  end

  before { allow_any_instance_of(described_class).to receive(:smtp_config_set_or_development?).and_return(true) }

  it 'links the automation email to the conversation in the front' do
    mail = described_class.with({}).conversation_creation(conversation, team, 'Mensagem da automação').deliver_now

    expect(mail.to).to eq([agent.email])
    link = "#{ENV.fetch('FRONTEND_URL', 'http://localhost:5173').chomp('/')}/conversations/#{conversation.id}"
    expect(mail.body.encoded).to include(link)
  end
end
