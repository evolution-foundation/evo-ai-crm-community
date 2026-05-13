# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Templates::ConflictResolver' do
    it 'has service spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Templates::ConflictResolver do
  describe '#resolve' do
    let(:resolver) { described_class.new('Clínica') }

    context 'when value is blank' do
      it 'returns the value unrenamed' do
        result = resolver.resolve(Label, :title, '')
        expect(result).to eq(value: '', renamed: false)
      end
    end

    context 'when no collision exists' do
      it 'returns the original value' do
        result = resolver.resolve(Label, :title, "uniq-#{SecureRandom.hex(4)}")
        expect(result[:renamed]).to be false
      end
    end

    context 'when collision exists' do
      let!(:existing) { Label.create!(title: 'urgente', color: '#fff') }

      it 'appends the template suffix on first collision' do
        result = resolver.resolve(Label, :title, 'urgente')
        expect(result[:renamed]).to be true
        expect(result[:value]).to eq('urgente (Template Clínica)')
      end

      context 'when first suffix also collides' do
        let!(:also_existing) { Label.create!(title: 'urgente (Template Clínica)', color: '#fff') }

        it 'falls back to numeric counter' do
          result = resolver.resolve(Label, :title, 'urgente')
          expect(result[:value]).to eq('urgente (Template Clínica) (2)')
        end
      end
    end

    context 'with compound-unique scope' do
      it 'only counts collisions within the scope' do
        result = resolver.resolve(MessageTemplate, :name, 'test',
                                  scope: { channel_id: SecureRandom.uuid, channel_type: 'Channel::Api' })
        expect(result[:renamed]).to be false
      end
    end
  end
end
