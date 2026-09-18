# frozen_string_literal: true

require 'rails_helper'

# An echo is a message the agent typed on the phone: WhatsApp hands it back to the CRM with
# no identity attached. The old fallback was the first row of the users table, which on a
# shared install is a stranger from another account.
#
# The inbox here is a web widget on purpose: these handlers only read `inbox.id`, and a real
# Channel::Whatsapp would drag webhook subscription into a spec about authorship.
RSpec.describe 'Outgoing echo author' do # rubocop:disable RSpec/DescribeClass
  let!(:stranger) { User.create!(name: 'Stranger', email: "stranger-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: "Inbox #{SecureRandom.hex(3)}", channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  describe 'Evolution Go' do
    let(:service) { Whatsapp::IncomingMessageEvolutionGoService.new(inbox: inbox, params: { event: 'Message', data: {} }) }

    def build_message(from_me:)
      service.instance_variable_set(:@inbox, inbox)
      service.instance_variable_set(:@contact, contact)
      service.instance_variable_set(:@evolution_go_info,
                                    { ID: SecureRandom.hex(6), Chat: '5511988888888@s.whatsapp.net',
                                      Sender: '5511988888888@s.whatsapp.net', IsFromMe: from_me,
                                      IsGroup: false, Type: 'conversation', Timestamp: '2026-09-17T10:00:00Z' })
      service.instance_variable_set(:@evolution_go_message, { conversation: 'oi' })
      service.send(:build_message_attributes, conversation)
      service.instance_variable_get(:@message)
    end

    it 'leaves the echo without an author' do
      message = build_message(from_me: true)

      expect(message.sender).to be_nil
      expect(message.sender_type).to be_nil
    end

    it 'never reaches for an unrelated user' do
      expect(build_message(from_me: true).sender_id).not_to eq(stranger.id)
    end

    it 'marks the echo as typed on the device' do
      expect(build_message(from_me: true).content_attributes['sent_from_device']).to be(true)
    end

    it 'still credits an inbound message to the contact' do
      message = build_message(from_me: false)

      expect(message.sender).to eq(contact)
      expect(message.content_attributes['sent_from_device']).to be_nil
    end
  end

  describe 'Evolution API' do
    let(:service) { Whatsapp::IncomingMessageEvolutionService.new(inbox: inbox, params: { event: 'messages.upsert', data: {} }) }

    def build_message(from_me:)
      service.instance_variable_set(:@inbox, inbox)
      service.instance_variable_set(:@contact, contact)
      service.instance_variable_set(:@conversation, conversation)
      service.instance_variable_set(:@raw_message,
                                    { key: { id: SecureRandom.hex(6), fromMe: from_me,
                                             remoteJid: '5511988888888@s.whatsapp.net' },
                                      messageTimestamp: 1_758_105_600,
                                      message: { conversation: 'oi' } })
      service.send(:build_message_attributes)
      service.instance_variable_get(:@message)
    end

    it 'leaves the echo without an author' do
      message = build_message(from_me: true)

      expect(message.sender).to be_nil
      expect(message.sender_type).to be_nil
    end

    it 'never reaches for an unrelated user' do
      expect(build_message(from_me: true).sender_id).not_to eq(stranger.id)
    end

    it 'marks the echo as typed on the device' do
      expect(build_message(from_me: true).content_attributes['sent_from_device']).to be(true)
    end

    it 'still credits an inbound message to the contact' do
      message = build_message(from_me: false)

      expect(message.sender).to eq(contact)
      expect(message.content_attributes['sent_from_device']).to be_nil
    end
  end

  describe 'Evolution history sync' do
    let(:job) { Webhooks::WhatsappEventsJob.new }
    let(:whatsapp_channel) { instance_double(Channel::Whatsapp, inbox: inbox) }

    def sync(from_me:)
      job.send(:process_evolution_sync_message, whatsapp_channel, conversation,
               { 'key' => { 'id' => SecureRandom.hex(6), 'fromMe' => from_me },
                 'message' => { 'conversation' => 'oi' },
                 'messageTimestamp' => 1_758_105_600,
                 'messageType' => 'conversation',
                 'status' => 'DELIVERED' })
      conversation.messages.reorder(:created_at).last
    end

    it 'leaves a synced outgoing message without an author, marked as typed on the device' do
      message = sync(from_me: true)

      expect(message.sender).to be_nil
      expect(message.sender_type).to be_nil
      expect(message.content_attributes['sent_from_device']).to be(true)
    end

    it 'still credits a synced inbound message to the contact' do
      message = sync(from_me: false)

      expect(message.sender).to eq(contact)
      expect(message.content_attributes['sent_from_device']).to be_nil
    end
  end

  # Narrow on purpose: it guards the literal `User.first`, not every way of reaching for an
  # arbitrary user. The deliberate `User.order(:created_at).first` task-creator fallback in
  # pipeline_tasks_controller is out of scope and must keep passing.
  describe 'the literal User.first is gone from live code' do
    it 'no longer hands User.first to a message as its author' do
      root = Rails.root
      offenders = Dir.glob(root.join('{app,lib}/**/*.rb')).select do |path|
        File.read(path).include?('User.first')
      end

      expect(offenders).to be_empty,
                           "User.first is back in: #{offenders.map { |f| f.sub("#{root}/", '') }.join(', ')}"
    end
  end
end
