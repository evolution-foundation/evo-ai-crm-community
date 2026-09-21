require 'rails_helper'

RSpec.describe Whatsapp::IncomingMessageWahaService do
  let(:channel) { instance_double(Channel::Whatsapp, id: 'chan-1') }
  let(:inbox) { instance_double(Inbox, id: 'inbox-1', channel: channel, archived?: false, lock_to_single_conversation: false) }

  def service_for(event, payload)
    described_class.new(inbox: inbox, params: { event: event, session: 'default', payload: payload })
  end

  describe 'message event' do
    it 'creates a contact/inbox via ContactInboxWithContactBuilder with a normalized source_id' do
      payload = { 'id' => 'true_5511988887777@c.us_ABC', 'from' => '5511988887777@c.us', 'fromMe' => false, 'body' => 'oi', 'hasMedia' => false }
      contact_inbox = instance_double(ContactInbox, contact: instance_double(Contact, id: 'contact-1'), id: 'ci-1')
      conversation = instance_double(Conversation, messages: double(build: instance_double(Message, save!: true, attachments: [])))

      expect(Whatsapp::PhoneNumberNormalizer).to receive(:call).with('5511988887777').and_call_original
      expect(ContactInboxWithContactBuilder).to receive(:new).with(
        hash_including(source_id: '5511988887777', inbox: inbox)
      ).and_return(instance_double(ContactInboxWithContactBuilder, perform: contact_inbox))
      allow(contact_inbox).to receive(:conversations).and_return(double(where: double(not: double(last: nil)), last: nil))
      allow(Conversation).to receive(:find_or_create_by!).and_return(conversation)

      service_for('message', payload).perform
    end

    it 'skips messages sent by the channel itself (fromMe: true)' do
      payload = { 'id' => 'true_x_1', 'from' => '5511988887777@c.us', 'fromMe' => true, 'body' => 'oi' }

      expect(ContactInboxWithContactBuilder).not_to receive(:new)

      service_for('message', payload).perform
    end
  end

  describe 'session.status event' do
    it 'marks the channel connected when status is WORKING' do
      payload = { 'name' => 'default', 'status' => 'WORKING' }
      expect(channel).to receive(:mark_connected!)

      service_for('session.status', payload).perform
    end

    it 'updates provider_connection to closed when status is FAILED' do
      payload = { 'name' => 'default', 'status' => 'FAILED' }
      expect(channel).to receive(:update_provider_connection!).with(hash_including('connection' => 'close'))

      service_for('session.status', payload).perform
    end

    it 'stores the QR data when status is SCAN_QR_CODE and a qr field is present' do
      payload = { 'name' => 'default', 'status' => 'SCAN_QR_CODE', 'qr' => 'data:image/png;base64,AAA' }
      expect(channel).to receive(:update_provider_connection!).with(hash_including('connection' => 'connecting', 'qr_data_url' => 'data:image/png;base64,AAA'))

      service_for('session.status', payload).perform
    end
  end
end
