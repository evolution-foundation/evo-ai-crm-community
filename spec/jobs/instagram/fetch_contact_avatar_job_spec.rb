# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Instagram::FetchContactAvatarJob do
  let(:avatar) { instance_double(ActiveStorage::Attached::One, attached?: false) }
  let(:contact) { instance_double(Contact, avatar: avatar) }
  let(:inbox) { instance_double(Inbox, instagram?: true) }
  let(:contact_inbox) do
    instance_double(ContactInbox, id: 'contact-inbox-1', source_id: 'ig-user-1', inbox: inbox, contact: contact)
  end
  let(:fetcher) { instance_double(Instagram::ContactProfileFetcher) }
  let(:contact_inbox_scope) { instance_double(ActiveRecord::Relation) }
  let(:response) do
    instance_double(
      HTTParty::Response,
      success?: true,
      code: 200,
      body: { profile_pic: 'https://cdn.example/avatar.jpg' }.to_json
    )
  end

  before do
    allow(ContactInbox).to receive(:includes).with(:inbox, contact: :avatar_attachment).and_return(contact_inbox_scope)
    allow(contact_inbox_scope).to receive(:find_by).with(id: 'contact-inbox-1').and_return(contact_inbox)
    allow(Instagram::ContactProfileFetcher).to receive(:new).with(inbox: inbox).and_return(fetcher)
    allow(fetcher).to receive(:call).with('ig-user-1').and_return(response)
  end

  it 'enqueues the safe avatar downloader when Instagram returns profile_pic' do
    expect(Avatar::AvatarFromUrlJob).to receive(:perform_later)
      .with(contact, 'https://cdn.example/avatar.jpg')

    described_class.new.perform('contact-inbox-1')
  end

  it 'does not call Instagram when the contact already has an avatar' do
    allow(avatar).to receive(:attached?).and_return(true)

    expect(fetcher).not_to receive(:call)
    expect(Avatar::AvatarFromUrlJob).not_to receive(:perform_later)

    described_class.new.perform('contact-inbox-1')
  end

  it 'skips profiles that Meta no longer makes available' do
    unavailable = instance_double(HTTParty::Response, success?: false, code: 400)
    allow(fetcher).to receive(:call).and_return(unavailable)
    allow(Rails.logger).to receive(:warn)

    expect(Avatar::AvatarFromUrlJob).not_to receive(:perform_later)

    described_class.new.perform('contact-inbox-1')
  end

  it 'raises a retryable error for transient Meta failures' do
    transient_failure = instance_double(HTTParty::Response, success?: false, code: 500)
    allow(fetcher).to receive(:call).and_return(transient_failure)

    expect { described_class.new.perform('contact-inbox-1') }
      .to raise_error(Instagram::FetchContactAvatarJob::TransientProfileError)
  end
end
