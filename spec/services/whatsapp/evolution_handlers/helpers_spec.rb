# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Whatsapp::EvolutionHandlers::Helpers' do
    it 'has spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

# CRM-22: a reaction carries the emoji as content, so only the type skip keeps it from becoming a bubble.
RSpec.describe Whatsapp::EvolutionHandlers::Helpers do
  let(:host_class) do
    Class.new do
      include Whatsapp::EvolutionHandlers::Helpers

      def initialize(raw_message)
        @raw_message = raw_message
      end
    end
  end

  subject(:helper) { host_class.new(raw_message) }

  describe '#ignore_message?' do
    context 'when the raw payload is a reactionMessage with a non-blank emoji' do
      let(:raw_message) do
        {
          key: { id: 'msg-1', fromMe: false, remoteJid: '55@s.whatsapp.net' },
          message: { reactionMessage: { text: '👍', key: { id: 'target' } } }
        }
      end

      it 'returns true (skip) so no bubble is materialised' do
        expect(helper.send(:message_type)).to eq('reaction')
        expect(helper.send(:ignore_message?)).to be(true)
      end
    end

    context 'when the raw payload is a reaction removal (empty text)' do
      let(:raw_message) do
        {
          key: { id: 'msg-2', fromMe: false, remoteJid: '55@s.whatsapp.net' },
          message: { reactionMessage: { text: '', key: { id: 'target' } } }
        }
      end

      it 'returns true (skip)' do
        expect(helper.send(:ignore_message?)).to be(true)
      end
    end

    context 'when the raw payload is protocolMessage' do
      let(:raw_message) do
        { key: { id: 'x' }, message: { protocolMessage: { type: 'REVOKE' } } }
      end

      it 'returns true (skip)' do
        expect(helper.send(:ignore_message?)).to be(true)
      end
    end

    context 'when the raw payload is an unsupported type (blank content, non-media)' do
      let(:raw_message) do
        { key: { id: 'x' }, message: { messageContextInfo: {} } }
      end

      it 'returns true (skip)' do
        expect(helper.send(:ignore_message?)).to be(true)
      end
    end

    context 'when the raw payload is a plain text message' do
      let(:raw_message) do
        { key: { id: 'x' }, message: { conversation: 'hi' } }
      end

      it 'returns false (process)' do
        expect(helper.send(:ignore_message?)).to be(false)
      end
    end

    context 'when the raw payload is an image without caption' do
      let(:raw_message) do
        { key: { id: 'x' }, message: { imageMessage: { mimetype: 'image/jpeg' } } }
      end

      it 'returns false (process — media attachment overrides blank content)' do
        expect(helper.send(:ignore_message?)).to be(false)
      end
    end

    context 'when the raw payload is a location (renderable, not skipped)' do
      let(:raw_message) do
        { key: { id: 'x' }, message: { locationMessage: { degreesLatitude: 1.0, degreesLongitude: 2.0 } } }
      end

      it 'returns false (process)' do
        expect(helper.send(:ignore_message?)).to be(false)
      end
    end
  end
end
