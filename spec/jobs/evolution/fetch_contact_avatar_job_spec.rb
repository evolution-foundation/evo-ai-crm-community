# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Evolution::FetchContactAvatarJob do
  let(:contact_id) { 'contact-uuid' }
  let(:channel_id) { 'channel-uuid' }
  let(:phone_number) { '5511999999999' }
  let(:contact) { instance_double(Contact, id: contact_id, avatar: avatar_double) }
  let(:avatar_double) { instance_double(ActiveStorage::Attached::One, attached?: false) }
  let(:channel) { instance_double(Channel::Whatsapp, id: channel_id) }
  let(:provider_service) { instance_double(Whatsapp::Providers::EvolutionService) }

  before do
    allow(Contact).to receive(:find_by).with(id: contact_id).and_return(contact)
    allow(Channel::Whatsapp).to receive(:find_by).with(id: channel_id).and_return(channel)
    allow(Whatsapp::Providers::EvolutionService).to receive(:new)
      .with(whatsapp_channel: channel)
      .and_return(provider_service)
  end

  it 'schedules the download (via the lock-releasing wrapper) when the provider returns a URL' do
    allow(provider_service).to receive(:fetch_profile_picture_url).with(phone_number)
                                                                  .and_return('https://cdn.example.com/profile.jpg')

    expect(Whatsapp::EvolutionHandlers::AvatarDownloadJob).to receive(:perform_later)
      .with(contact, 'https://cdn.example.com/profile.jpg')

    described_class.new.perform(contact_id, phone_number, channel_id)
  end

  it 'skips download when the provider returns no URL' do
    allow(provider_service).to receive(:fetch_profile_picture_url).and_return(nil)

    expect(Whatsapp::EvolutionHandlers::AvatarDownloadJob).not_to receive(:perform_later)

    described_class.new.perform(contact_id, phone_number, channel_id)
  end

  it 'releases the enqueue debounce lock when no URL is found, so a later message can retry the fetch' do
    allow(provider_service).to receive(:fetch_profile_picture_url).and_return(nil)

    expect(Whatsapp::EvolutionHandlers::AvatarEnqueueGuard).to receive(:release_avatar_enqueue_lock).with(contact_id)

    described_class.new.perform(contact_id, phone_number, channel_id)
  end

  it 'does not release the debounce lock itself when a URL was found — the download wrapper job owns that' do
    allow(provider_service).to receive(:fetch_profile_picture_url).and_return('https://cdn.example.com/profile.jpg')
    allow(Whatsapp::EvolutionHandlers::AvatarDownloadJob).to receive(:perform_later)

    expect(Whatsapp::EvolutionHandlers::AvatarEnqueueGuard).not_to receive(:release_avatar_enqueue_lock)

    described_class.new.perform(contact_id, phone_number, channel_id)
  end

  it 'short-circuits when the contact already has an avatar attached' do
    allow(avatar_double).to receive(:attached?).and_return(true)

    expect(provider_service).not_to receive(:fetch_profile_picture_url)
    expect(Whatsapp::EvolutionHandlers::AvatarDownloadJob).not_to receive(:perform_later)

    described_class.new.perform(contact_id, phone_number, channel_id)
  end

  it 'does nothing when the contact cannot be found' do
    allow(Contact).to receive(:find_by).with(id: contact_id).and_return(nil)

    expect(Whatsapp::EvolutionHandlers::AvatarDownloadJob).not_to receive(:perform_later)

    described_class.new.perform(contact_id, phone_number, channel_id)
  end

  describe 'retry behavior' do
    it 'configures retry_on for network timeouts so transient failures recover' do
      retry_classes = described_class.rescue_handlers.map(&:first).map(&:to_s)
      expect(retry_classes).to include('Net::OpenTimeout', 'Net::ReadTimeout')
    end

    it 'propagates non-retried StandardError so Sidekiq + Sentry capture it' do
      allow(provider_service).to receive(:fetch_profile_picture_url).and_raise(StandardError, 'boom')

      expect { described_class.new.perform(contact_id, phone_number, channel_id) }.to raise_error(StandardError, 'boom')
    end
  end
end
