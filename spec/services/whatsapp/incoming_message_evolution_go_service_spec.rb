# frozen_string_literal: true

require 'rails_helper'

# Evolution Go's real webhook event names (verified against
# pkg/whatsmeow/service/whatsmeow.go's postMap["event"] assignments and the
# case list at whatsmeow.go:2095) are: Connected, PairSuccess, TemporaryBan,
# LoggedOut, ConnectFailure, Disconnected — PascalCase, matching what this
# service's `case event_type` already expects for PairSuccess/LoggedOut.
# Before this spec, only PairSuccess and LoggedOut were handled; the other
# four (most importantly Connected and Disconnected) silently no-op'd,
# which is exactly why a normal reconnect never cleared a stale "deslogado"
# banner, and a real drop after inactivity never surfaced anywhere.
RSpec.describe Whatsapp::IncomingMessageEvolutionGoService do
  let(:channel) { instance_double(Channel::Whatsapp, id: 'channel-1') }
  let(:inbox) { instance_double(Inbox, id: 'inbox-1', channel: channel, archived?: false) }

  def service_for(event, data = {})
    described_class.new(inbox: inbox, params: { event: event, instanceId: 'vendedor-2', data: data })
  end

  describe "'Connected' event" do
    it 'realigns the channel to connected, clearing any stale reauthorization/disconnected state' do
      expect(channel).to receive(:mark_connected!)

      service_for('Connected').perform
    end
  end

  describe "'Disconnected' event" do
    it 'reflects the disconnected state without demanding reauthorization (whatsmeow auto-reconnects)' do
      expect(channel).not_to receive(:prompt_reauthorization!)
      expect(channel).to receive(:update_provider_connection!).with(
        hash_including('connection' => 'close')
      )

      service_for('Disconnected').perform
    end
  end

  describe "'ConnectFailure' event" do
    it 'reflects the disconnected state with the failure reason, without demanding reauthorization' do
      expect(channel).not_to receive(:prompt_reauthorization!)
      expect(channel).to receive(:update_provider_connection!).with(
        hash_including('connection' => 'close', 'error' => a_string_matching(/timeout/))
      )

      service_for('ConnectFailure', { reason: 'timeout' }).perform
    end
  end

  describe "'TemporaryBan' event" do
    it 'prompts reauthorization and reflects the disconnected state, same severity as LoggedOut' do
      expect(channel).to receive(:prompt_reauthorization!)
      expect(channel).to receive(:update_provider_connection!).with(
        hash_including('connection' => 'close')
      )

      service_for('TemporaryBan').perform
    end
  end

  describe 'an unrecognized event' do
    it 'logs a warning and takes no action, same as before' do
      expect(channel).not_to receive(:mark_connected!)
      expect(channel).not_to receive(:update_provider_connection!)
      expect(channel).not_to receive(:prompt_reauthorization!)

      service_for('SomeFutureEvent').perform
    end
  end
end
