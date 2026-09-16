# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ConversationChannelMove do
  # hub_managed? (provider_config['evolution_hub'] present) short-circuits the
  # credential probe in Channel::Whatsapp#validate_provider_config, so create!
  # doesn't need a real Meta/Evolution API to succeed (mirrors
  # spec/controllers/api/v1/inboxes_controller_spec.rb).
  def build_whatsapp_channel(phone_number: "+55119#{SecureRandom.hex(4)}")
    Channel::Whatsapp.create!(
      phone_number: phone_number,
      provider: 'whatsapp_cloud',
      provider_config: { 'api_key' => '', 'phone_number_id' => '', 'evolution_hub' => { 'status' => 'active' } }
    )
  end

  def build_email_channel
    Channel::Email.create!(email: "channel-#{SecureRandom.hex(4)}@example.com")
  end

  def build_web_widget_channel
    Channel::WebWidget.create!(website_url: 'https://widget.example.com')
  end

  def build_inbox(channel)
    Inbox.create!(name: "Inbox #{SecureRandom.hex(4)}", channel: channel)
  end

  def build_contact(phone_number: nil, email: nil)
    Contact.create!(name: 'Test Contact', phone_number: phone_number, email: email)
  end

  def build_conversation(inbox:, contact:)
    # source_id must satisfy ContactInbox's per-channel-type format validation; a
    # plain numeric string is valid for every channel type used in this spec
    # (Whatsapp requires digits, Email/WebWidget accept any non-blank string).
    contact_inbox = ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.random_number(10**10).to_s)
    Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
  end

  describe '#eligible_move_target?' do
    it 'is eligible for a same-type, non-archived inbox' do
      whatsapp_inbox_a = build_inbox(build_whatsapp_channel)
      whatsapp_inbox_b = build_inbox(build_whatsapp_channel)
      contact = build_contact(phone_number: '+5511999999999')
      conversation = build_conversation(inbox: whatsapp_inbox_a, contact: contact)

      expect(conversation.eligible_move_target?(whatsapp_inbox_b)).to be true
    end

    it 'is not eligible for an archived target inbox' do
      whatsapp_inbox_a = build_inbox(build_whatsapp_channel)
      whatsapp_inbox_b = build_inbox(build_whatsapp_channel)
      whatsapp_inbox_b.update!(archived_at: Time.current)
      contact = build_contact(phone_number: '+5511999999999')
      conversation = build_conversation(inbox: whatsapp_inbox_a, contact: contact)

      expect(conversation.eligible_move_target?(whatsapp_inbox_b)).to be false
    end

    it 'is eligible for a cross-type Email target when the contact has an email' do
      whatsapp_inbox = build_inbox(build_whatsapp_channel)
      email_inbox = build_inbox(build_email_channel)
      contact = build_contact(phone_number: '+5511999999999', email: 'a@example.com')
      conversation = build_conversation(inbox: whatsapp_inbox, contact: contact)

      expect(conversation.eligible_move_target?(email_inbox)).to be true
    end

    it 'is not eligible for a cross-type Email target when the contact has no email' do
      whatsapp_inbox = build_inbox(build_whatsapp_channel)
      email_inbox = build_inbox(build_email_channel)
      contact = build_contact(phone_number: '+5511999999999', email: nil)
      conversation = build_conversation(inbox: whatsapp_inbox, contact: contact)

      expect(conversation.eligible_move_target?(email_inbox)).to be false
    end

    it 'is not eligible for a Chat Widget target, ever' do
      whatsapp_inbox = build_inbox(build_whatsapp_channel)
      widget_inbox = build_inbox(build_web_widget_channel)
      contact = build_contact(phone_number: '+5511999999999')
      conversation = build_conversation(inbox: whatsapp_inbox, contact: contact)

      expect(conversation.eligible_move_target?(widget_inbox)).to be false
    end
  end
end
