# frozen_string_literal: true

require 'rails_helper'

# CRM-546 — the realtime audience has to match HTTP visibility. Pins the invariant
# "whoever can read it gets the frame" without prescribing the delivery mechanism:
# any stream the subscription listens to counts.
RSpec.describe RoomChannel, type: :channel do
  include ActiveJob::TestHelper

  let(:web_channel) { Channel::WebWidget.create!(website_url: 'https://audience.example.com') }
  let(:inbox) { Inbox.create!(name: 'Audience Inbox', channel: web_channel) }
  let(:contact) { Contact.create!(name: 'Visitor', email: "visitor-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: "aud-#{SecureRandom.hex(4)}") }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:user) { User.create!(name: 'Reader', email: "reader-#{SecureRandom.hex(4)}@test.com") }
  let(:auth_service) { instance_double(EvoAuthService) }

  before do
    allow(OnlineStatusTracker).to receive(:update_presence)
    allow(OnlineStatusTracker).to receive(:get_available_users).and_return([])
    allow(OnlineStatusTracker).to receive(:get_available_contacts).and_return([])
    # Agent subscriptions authenticate with the auth-service token (CRM-537).
    allow(EvoAuthService).to receive(:new).and_return(auth_service)
    stub_connection(warden_user: nil)
  end

  def grant_role(reader, key, name)
    role = Role.find_by(key: key) || Role.create!(key: key, name: name)
    UserRole.create!(user: reader, role: role)
  end

  def subscribe_as(reader)
    token = "jwt-#{SecureRandom.hex(8)}"
    allow(auth_service).to receive(:validate_token)
      .with(token: token, token_type: 'bearer')
      .and_return({ 'user' => { 'id' => reader.id, 'email' => reader.email } })
    subscribe(user_id: reader.id.to_s, pubsub_token: reader.pubsub_token, access_token: token)
    expect(subscription).to be_confirmed
  end

  # The broadcast job is what actually hits the cable, so it runs inline here.
  def deliver_incoming_message
    perform_enqueued_jobs(only: ActionCableBroadcastJob) do
      Message.create!(inbox: inbox, conversation: conversation, message_type: :incoming, content: 'hello')
    end
  end

  def frames_received_for(message)
    subscription.streams
                .flat_map { |stream| ActionCable.server.pubsub.broadcasts(stream) }
                .map { |raw| JSON.parse(raw) }
                .select { |frame| frame['event'] == 'message.created' && frame.dig('data', 'id') == message.id }
  end

  describe 'inbound message.created audience' do
    it 'reaches an inbox member live (control)' do
      InboxMember.create!(inbox: inbox, user: user)
      subscribe_as(user)

      message = deliver_incoming_message

      expect(frames_received_for(message)).not_to be_empty
    end

    it 'reaches an administrator who is not an inbox member' do
      grant_role(user, 'administrator', 'Administrator')
      subscribe_as(user)

      message = deliver_incoming_message

      expect(frames_received_for(message)).not_to be_empty
    end

    it 'never reaches an agent who is neither member nor administrator' do
      grant_role(user, 'agent', 'Agent')
      subscribe_as(user)

      message = deliver_incoming_message

      expect(frames_received_for(message)).to be_empty
    end
  end
end
