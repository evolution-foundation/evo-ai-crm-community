# frozen_string_literal: true

require 'rails_helper'

RSpec.describe InboxSerializer do
  describe 'archived_at field' do
    let(:channel) { Channel::Api.create! }

    it 'includes archived_at as ISO8601 string for archived inbox' do
      inbox = Inbox.create!(
        channel: channel,
        name: 'Archived Inbox',
        archived_at: Time.zone.parse('2026-01-01T00:00:00Z')
      )

      result = described_class.serialize(inbox)

      expect(result['archived_at']).to eq(inbox.archived_at.iso8601)
    end

    it 'includes a nil archived_at for an active inbox' do
      inbox = Inbox.create!(
        channel: channel,
        name: 'Active Inbox',
        archived_at: nil
      )

      result = described_class.serialize(inbox)

      expect(result['archived_at']).to be_nil
    end
  end
end
