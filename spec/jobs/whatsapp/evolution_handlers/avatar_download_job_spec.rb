# frozen_string_literal: true

require 'rails_helper'

# Sourcery finding (bug_risk, PR #373): the enqueue debounce lock was only
# released when no profile picture URL was found (Evolution::FetchContactAvatarJob).
# When a URL WAS found but the download itself failed or never attached (blocked
# SSRF, 404, transient network error), nothing ever released the lock, leaving the
# contact locked out of a retry for the full one-hour TTL. This job wraps the
# actual download so the lock always releases once the attempt is over, whatever
# the outcome.
RSpec.describe Whatsapp::EvolutionHandlers::AvatarDownloadJob do
  let(:contact) { instance_double(Contact, id: 'contact-uuid') }
  let(:avatar_url) { 'https://cdn.example.com/profile.jpg' }

  it 'performs the download and releases the enqueue lock on success' do
    inner = instance_double(Avatar::AvatarFromUrlJob, perform: true)
    allow(Avatar::AvatarFromUrlJob).to receive(:new).and_return(inner)

    expect(inner).to receive(:perform).with(contact, avatar_url)
    expect(Whatsapp::EvolutionHandlers::AvatarEnqueueGuard).to receive(:release_avatar_enqueue_lock).with('contact-uuid')

    described_class.new.perform(contact, avatar_url)
  end

  it 'still releases the lock when the download silently fails to attach anything' do
    inner = instance_double(Avatar::AvatarFromUrlJob, perform: nil)
    allow(Avatar::AvatarFromUrlJob).to receive(:new).and_return(inner)

    expect(Whatsapp::EvolutionHandlers::AvatarEnqueueGuard).to receive(:release_avatar_enqueue_lock).with('contact-uuid')

    described_class.new.perform(contact, avatar_url)
  end

  it 'releases the lock even when the download raises, and still propagates the error' do
    inner = instance_double(Avatar::AvatarFromUrlJob)
    allow(Avatar::AvatarFromUrlJob).to receive(:new).and_return(inner)
    allow(inner).to receive(:perform).and_raise(StandardError, 'boom')

    expect(Whatsapp::EvolutionHandlers::AvatarEnqueueGuard).to receive(:release_avatar_enqueue_lock).with('contact-uuid')

    expect { described_class.new.perform(contact, avatar_url) }.to raise_error(StandardError, 'boom')
  end
end
