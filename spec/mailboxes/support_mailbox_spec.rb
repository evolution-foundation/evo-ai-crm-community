# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SupportMailbox, type: :mailbox do
  let(:email_channel) { Channel::Email.create!(email: 'support@example.com', forward_to_email: 'forward@example.com') }
  let(:inbox) { Inbox.create!(name: 'Support', channel: email_channel) }

  def raw_email(to:, from: 'customer@test.com')
    <<~EML
      From: #{from}
      To: #{to}
      Subject: Help needed
      Message-ID: <#{SecureRandom.hex(8)}@test.com>
      Content-Type: text/plain

      Hello, I need help.
    EML
  end

  # Parse a raw email into a Mail::Message and invoke SupportMailbox directly,
  # bypassing ActionMailbox::InboundEmail so tests do not require
  # active_storage_attachments wiring (mirrors bounce_mailbox_spec.rb). Unlike
  # BounceMailbox, SupportMailbox#process depends on ivars set by its
  # before_processing chain (find_channel, load_inbox, decorate_mail); running
  # them through ActionMailbox's real callback machinery needs a full
  # InboundEmail record, so we invoke that chain's methods directly instead.
  def process_email(source)
    inbound_mail = Mail.from_source(source)
    inbound = Struct.new(:mail).new(inbound_mail)
    mailbox = SupportMailbox.allocate
    mailbox.instance_variable_set(:@inbound_email, inbound)
    mailbox.define_singleton_method(:mail) { inbound_mail }
    mailbox.send(:find_channel)
    mailbox.send(:load_inbox)
    mailbox.send(:decorate_mail)
    mailbox.process
  end

  describe '#process' do
    it 'creates a conversation and message for an active inbox' do
      inbox

      expect { process_email(raw_email(to: email_channel.email)) }
        .to change(Conversation, :count).by(1)
        .and change(Message, :count).by(1)
    end

    it 'does not create a conversation or message when the inbox is archived' do
      inbox.update!(archived_at: Time.current)

      expect { process_email(raw_email(to: email_channel.email)) }.not_to change(Conversation, :count)
      expect { process_email(raw_email(to: email_channel.email)) }.not_to change(Message, :count)
    end
  end
end
