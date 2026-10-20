require 'rails_helper'
require 'webmock/rspec'
WebMock.disable_net_connect!(allow_localhost: true)

RSpec.describe 'Concurrent Cloud observations', :standby_concurrency do
  self.use_transactional_tests = false

  it 'serializes concurrent workers before creating contact, conversation and message' do
    ActiveJob::Base.queue_adapter = :test
    allow_any_instance_of(Channel::Whatsapp).to receive(:subscribe)
    allow_any_instance_of(Channel::Whatsapp).to receive(:sync_templates)
    allow(ActionCableListener.instance).to receive(:message_created)
    channel = Channel::Whatsapp.new(provider: 'whatsapp_cloud', phone_number: '+15550000999',
      provider_config: { phone_number_id: 'CONCURRENT_PHONE', waba_id: 'WABA_TEST', api_key: 'synthetic' })
    channel.save!(validate: false)
    inbox = Inbox.create!(name: 'Concurrent synthetic inbox', channel: channel)
    payload = { object: 'whatsapp_business_account', entry: [{ id: 'WABA_TEST', changes: [{ field: 'standby',
      value: { metadata: { phone_number_id: 'CONCURRENT_PHONE' }, standby: { message_echoes: [{
        id: 'wamid.concurrent', timestamp: '1780000000', message: { to: '15550000998', type: 'text', text: { body: 'Concurrent' } }
      }] } } }] }] }
    threads = 4.times.map do
      Thread.new { ActiveRecord::Base.connection_pool.with_connection { Webhooks::WhatsappEventsJob.new.perform(payload.deep_dup) } }
    end
    threads.each(&:value)
    expect(inbox.messages.where(source_id: 'wamid.concurrent').count).to eq(1)
    expect(inbox.contact_inboxes.count).to eq(1)
    expect(inbox.conversations.count).to eq(1)
  ensure
    if inbox
      contact_ids = inbox.contact_inboxes.pluck(:contact_id)
      Message.where(inbox_id: inbox.id).delete_all
      Conversation.where(inbox_id: inbox.id).delete_all
      ContactInbox.where(inbox_id: inbox.id).delete_all
      Inbox.where(id: inbox.id).delete_all
      Contact.where(id: contact_ids).delete_all
    end
    Channel::Whatsapp.where(id: channel.id).delete_all if channel
  end
end
