# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::PresenceEventFilter do
  describe '.typing?' do
    context 'with provider :evolution' do
      it 'is true for composing and recording' do
        expect(described_class.typing?(:evolution, 'composing')).to eq(true)
        expect(described_class.typing?(:evolution, 'recording')).to eq(true)
      end

      it 'is false for available, unavailable and paused' do
        expect(described_class.typing?(:evolution, 'available')).to eq(false)
        expect(described_class.typing?(:evolution, 'unavailable')).to eq(false)
        expect(described_class.typing?(:evolution, 'paused')).to eq(false)
      end
    end

    context 'with provider :evolution_go' do
      it 'is true for composing' do
        expect(described_class.typing?(:evolution_go, 'composing')).to eq(true)
      end

      it 'is false for paused' do
        expect(described_class.typing?(:evolution_go, 'paused')).to eq(false)
      end
    end

    context 'with provider :waha' do
      it 'is true for typing and recording' do
        expect(described_class.typing?(:waha, 'typing')).to eq(true)
        expect(described_class.typing?(:waha, 'recording')).to eq(true)
      end

      it 'is false for online, offline and paused' do
        expect(described_class.typing?(:waha, 'online')).to eq(false)
        expect(described_class.typing?(:waha, 'offline')).to eq(false)
        expect(described_class.typing?(:waha, 'paused')).to eq(false)
      end
    end

    it 'is false for an unknown provider' do
      expect(described_class.typing?(:unknown, 'composing')).to eq(false)
    end

    it 'is false for a nil state' do
      expect(described_class.typing?(:evolution, nil)).to eq(false)
    end
  end
end
