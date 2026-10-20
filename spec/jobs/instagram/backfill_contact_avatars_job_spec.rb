# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Instagram::BackfillContactAvatarsJob do
  let(:inbox) { instance_double(Inbox, id: 'inbox-1', instagram?: true) }
  let(:missing_avatar) { instance_double(ActiveStorage::Attached::One, attached?: false) }
  let(:existing_avatar) { instance_double(ActiveStorage::Attached::One, attached?: true) }
  let(:missing_contact) { instance_double(Contact, avatar: missing_avatar) }
  let(:existing_contact) { instance_double(Contact, avatar: existing_avatar) }
  let(:missing_contact_inbox) { instance_double(ContactInbox, id: 'ci-1', contact: missing_contact) }
  let(:existing_contact_inbox) { instance_double(ContactInbox, id: 'ci-2', contact: existing_contact) }
  let(:job) { described_class.new }

  before do
    allow(Inbox).to receive(:find_by).with(id: 'inbox-1').and_return(inbox)
    allow(job).to receive(:contact_inbox_batch).and_return([missing_contact_inbox, existing_contact_inbox])
  end

  it 'enqueues only contacts that still lack an avatar' do
    expect(Instagram::FetchContactAvatarJob).to receive(:perform_later).with('ci-1')
    expect(Instagram::FetchContactAvatarJob).not_to receive(:perform_later).with('ci-2')

    job.perform('inbox-1')
  end

  it 'continues from the last record when a batch is full' do
    stub_const("#{described_class}::BATCH_SIZE", 1)
    allow(job).to receive(:contact_inbox_batch).and_return([missing_contact_inbox])
    allow(Instagram::FetchContactAvatarJob).to receive(:perform_later)

    expect(described_class).to receive(:perform_later).with('inbox-1', 'ci-1')

    job.perform('inbox-1')
  end
end
