# frozen_string_literal: true

require 'rails_helper'

# Regression spec: without a dedicated email? branch, InboxSerializer never
# put the connected mailbox address at the top level of the response — it
# only showed up nested under `channel` when include_channel was requested.
# The frontend's channel settings title and the Google/Microsoft OAuth
# reconnect flow both read `inbox.email` directly, so they silently broke
# ("sac (undefined)" title, "Email é obrigatório para reconexão" on reconnect)
# even though the mailbox was connected and working fine.
RSpec.describe InboxSerializer do
  describe '.serialize with an Email channel' do
    let(:channel) do
      Channel::Email.create!(
        email: 'sac@kaiabi.com',
        provider: 'google',
        provider_config: { access_token: 'token', refresh_token: 'refresh' }
      )
    end
    let(:inbox) { Inbox.create!(channel: channel, name: 'sac') }

    it 'exposes the connected mailbox address at the top level' do
      result = described_class.serialize(inbox)

      expect(result['email']).to eq('sac@kaiabi.com')
    end

    it 'still exposes it when include_channel is requested' do
      result = described_class.serialize(inbox, include_channel: true)

      expect(result['email']).to eq('sac@kaiabi.com')
      expect(result['channel']['email']).to eq('sac@kaiabi.com')
    end
  end
end
