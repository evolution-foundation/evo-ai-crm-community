# frozen_string_literal: true

require 'rails_helper'

# CRM-537: an agent subscription proves identity with the auth-service token, the
# same credential HTTP accepts. pubsub_token + user_id alone never open a stream.
RSpec.describe RoomChannel, type: :channel do
  let(:user) do
    User.create!(name: 'Agent', email: "room-#{SecureRandom.hex(4)}@test.com")
  end
  let(:other_user) do
    User.create!(name: 'Other', email: "other-#{SecureRandom.hex(4)}@test.com")
  end
  let(:web_channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: web_channel) }
  let(:contact) { Contact.create!(name: 'Test Contact', email: "contact-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: "test-#{SecureRandom.hex(4)}") }
  let(:auth_service) { instance_double(EvoAuthService) }

  before do
    allow(OnlineStatusTracker).to receive(:update_presence)
    allow(OnlineStatusTracker).to receive(:get_available_users).and_return([])
    allow(OnlineStatusTracker).to receive(:get_available_contacts).and_return([])
    allow(EvoAuthService).to receive(:new).and_return(auth_service)
    allow(auth_service).to receive(:validate_token).and_raise(EvoAuthService::ValidationError, 'Invalid token')
    stub_connection(warden_user: nil)
  end

  # Unique per example: the resolver caches validations by token hash.
  def issue_token_for(owner)
    token = "jwt-#{SecureRandom.hex(8)}"
    allow(auth_service).to receive(:validate_token)
      .with(token: token, token_type: 'bearer')
      .and_return({ 'user' => { 'id' => owner.id, 'email' => owner.email } })
    token
  end

  describe '#subscribed' do
    context 'with a valid access_token for the requested user_id' do
      it 'subscribes and streams from the user token' do
        subscribe(user_id: user.id.to_s, pubsub_token: user.pubsub_token, access_token: issue_token_for(user))

        expect(subscription).to be_confirmed
        expect(subscription).to have_stream_from(user.pubsub_token)
      end

      it 'streams from the current token when the given pubsub_token was rotated' do
        subscribe(user_id: user.id.to_s, pubsub_token: 'stale-token', access_token: issue_token_for(user))

        expect(subscription).to be_confirmed
        expect(subscription).to have_stream_from(user.pubsub_token)
        expect(subscription).not_to have_stream_from('stale-token')
      end
    end

    context 'when an anonymous connection holds another user token and id' do
      it 'rejects without an access_token' do
        subscribe(user_id: user.id.to_s, pubsub_token: user.pubsub_token)

        expect(subscription).to be_rejected
      end

      it 'rejects an access_token the auth service does not recognize' do
        subscribe(user_id: user.id.to_s, pubsub_token: user.pubsub_token, access_token: 'forged')

        expect(subscription).to be_rejected
      end
    end

    context 'when the access_token belongs to a third party' do
      it 'rejects when the authenticated user differs from user_id' do
        subscribe(user_id: user.id.to_s, pubsub_token: user.pubsub_token, access_token: issue_token_for(other_user))

        expect(subscription).to be_rejected
      end

      it 'never falls back to a warden user' do
        stub_connection(warden_user: user)

        subscribe(user_id: user.id.to_s, pubsub_token: user.pubsub_token)

        expect(subscription).to be_rejected
      end
    end

    context 'when the auth service is unavailable' do
      it 'rejects (fail-closed)' do
        allow(auth_service).to receive(:validate_token).and_raise(EvoAuthService::AuthenticationError, 'down')

        subscribe(user_id: user.id.to_s, pubsub_token: user.pubsub_token, access_token: 'jwt-any')

        expect(subscription).to be_rejected
      end
    end

    context 'with an unknown token_type' do
      it 'rejects' do
        subscribe(user_id: user.id.to_s, pubsub_token: user.pubsub_token, access_token: 'jwt-any', token_type: 'cookie')

        expect(subscription).to be_rejected
      end
    end

    context 'when update_presence fails after subscribing' do
      it 'swallows the error so ActionCable never logs the identifier' do
        subscribe(user_id: user.id.to_s, pubsub_token: user.pubsub_token, access_token: issue_token_for(user))
        allow(OnlineStatusTracker).to receive(:update_presence).and_raise(Redis::CannotConnectError, 'redis down')

        expect { perform :update_presence }.not_to raise_error
      end
    end

    context 'when a widget contact subscribes without user_id' do
      it 'subscribes with the contact_inbox pubsub_token' do
        subscribe(pubsub_token: contact_inbox.pubsub_token)

        expect(subscription).to be_confirmed
        expect(subscription).to have_stream_from(contact_inbox.pubsub_token)
      end

      it 'rejects a user pubsub_token presented as a contact token' do
        subscribe(pubsub_token: user.pubsub_token)

        expect(subscription).to be_rejected
      end

      it 'rejects an unknown token' do
        subscribe(pubsub_token: 'invalid-token')

        expect(subscription).to be_rejected
      end
    end
  end
end
