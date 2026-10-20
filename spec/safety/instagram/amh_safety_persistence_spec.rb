# Explicit isolated local PostgreSQL required; never use production credentials.
ENV['RAILS_ENV'] = 'test'
require_relative '../../../config/environment'
require 'active_job/test_helper'
require 'webmock/rspec'

RSpec.describe Instagram::AmhSafety do
  include ActiveJob::TestHelper

  around do |example|
    raise 'Use the isolated safety database' unless ActiveRecord::Base.connection_db_config.database == 'instagram_amh_safety_test'

    previous_ids = ENV.fetch('INSTAGRAM_AMH_INBOX_IDS', nil)
    previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    WebMock.disable_net_connect!
    ActiveRecord::Base.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  ensure
    ENV['INSTAGRAM_AMH_INBOX_IDS'] = previous_ids
    ActiveJob::Base.queue_adapter = previous_adapter
    clear_enqueued_jobs
    WebMock.allow_net_connect!
  end

  it 'persists a social contact without email and an inbound message, with no delivery on duplicate/retry' do
    channel = Channel::Instagram.create!(instagram_id: 'qa-account', access_token: 'fixture-inert', expires_at: 1.day.from_now)
    inbox = Inbox.create!(name: 'QA isolated Instagram', channel: channel)
    ENV['INSTAGRAM_AMH_INBOX_IDS'] = inbox.id
    contact_inbox = channel.reload.create_contact_inbox('qa-social', 'QA fixture')
    contact = contact_inbox.contact.reload
    expect(contact.email).to be_blank
    expect(described_class.blocked_contact?(contact)).to be true

    messaging = { sender: { id: 'qa-social' }, recipient: { id: 'qa-account' },
                  message: { mid: 'qa-inbound', text: 'QA isolated' } }.with_indifferent_access
    2.times { Messages::Instagram::MessageBuilder.new(messaging, inbox).perform }
    message = inbox.messages.find_by!(source_id: 'qa-inbound')
    expect(message).to be_incoming
    expect(inbox.messages.where(source_id: 'qa-inbound').count).to eq(1)
    expect(contact_inbox.reload.contact_id).to eq(contact.id)

    automated = message.conversation.messages.create!(inbox: inbox, message_type: :outgoing, content: 'QA blocked')
    2.times { SendReplyJob.new.perform(automated.id) }
    expect(enqueued_jobs.select { |job| job[:job] == SendReplyJob }.map { |job| job[:args] }).not_to include([automated.id])
    expect(WebMock).not_to have_requested(:post, /graph\.(instagram|facebook)\.com/)
  end
end
