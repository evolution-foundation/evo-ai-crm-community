# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MessageTemplates::Template::CsatSurvey, '#evaluate_regex_trigger' do
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "contact-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:trigger) { { 'type' => 'regex', 'field' => 'message_content', 'pattern' => 'Hello.*' } }

  def add_message(content, created_at)
    conversation.messages.create!(inbox: inbox, message_type: :incoming, content: content, created_at: created_at)
  end

  # Message has default_scope { order(created_at: :asc) }, which an appended
  # order(created_at: :desc) does not override: the trigger read the conversation's FIRST
  # message, so a long conversation was judged by what was said at the very start.
  it 'judges the latest message, not the first one' do
    add_message('Hello world', 1.day.ago)
    add_message('Goodbye world', 1.minute.ago)

    expect(described_class.new(conversation: conversation).send(:evaluate_regex_trigger, trigger)).to be false
  end

  it 'matches when the latest message matches' do
    add_message('Goodbye world', 1.day.ago)
    add_message('Hello world', 1.minute.ago)

    expect(described_class.new(conversation: conversation).send(:evaluate_regex_trigger, trigger)).to be true
  end
end
