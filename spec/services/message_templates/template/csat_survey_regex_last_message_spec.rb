# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MessageTemplates::Template::CsatSurvey do
  let(:channel) { Channel::Api.create! }
  let(:inbox) { Inbox.create!(name: 'CSAT Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'CSAT Contact') }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:service) { described_class.new(conversation: conversation) }

  before do
    inbox.update!(csat_config: {
                    'survey_rules' => {
                      'triggers' => [{ 'type' => 'regex', 'field' => 'message_content', 'pattern' => '^obrigad' }]
                    }
                  })
  end

  def message(content, at)
    conversation.messages.create!(inbox: inbox, message_type: :incoming, sender: contact, content: content, created_at: at)
  end

  it 'matches the regex against the latest message' do
    message('oi, preciso de ajuda', 10.minutes.ago)
    message('obrigado!', 1.minute.ago)

    expect(service.send(:should_send_csat_survey?)).to be(true)
  end

  it 'does not match an older message when the latest one differs' do
    message('obrigado!', 10.minutes.ago)
    message('ainda tenho uma dúvida', 1.minute.ago)

    expect(service.send(:should_send_csat_survey?)).to be(false)
  end
end
