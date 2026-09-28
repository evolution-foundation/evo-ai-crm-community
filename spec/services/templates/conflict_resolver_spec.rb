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

    # A label title rejects parentheses, so the default suffix is exercised on teams.
    context 'when collision exists' do
      let!(:existing) { Team.create!(name: 'urgente') }

      it 'appends the template suffix on first collision' do
        result = resolver.resolve(Team, :name, 'urgente')
        expect(result[:renamed]).to be true
        expect(result[:value]).to eq('urgente (Template Clínica)')
      end

      context 'when first suffix also collides' do
        let!(:also_existing) { Team.create!(name: 'urgente (Template Clínica)') }

        it 'falls back to numeric counter' do
          result = resolver.resolve(Team, :name, 'urgente')
          expect(result[:value]).to eq('urgente (Template Clínica) (2)')
        end
      end
    end

    context 'when the model ignores case' do
      before { Team.create!(name: 'Urgente') }

      it 'misses a name differing only in case by default' do
        expect(resolver.resolve(Team, :name, 'urgente')[:renamed]).to be false
      end

      it 'counts it as a collision once told the model ignores case' do
        result = resolver.with(case_sensitive: false).resolve(Team, :name, 'urgente')
        expect(result).to eq(value: 'urgente (Template Clínica)', renamed: true)
      end
    end

    context 'with a plain suffix' do
      let(:resolver) { described_class.new('Clínica & Co.').with(case_sensitive: false, plain: true) }

      before { Label.create!(title: 'urgente', color: '#fff') }

      it 'suffixes with letters, digits and spaces only' do
        result = resolver.resolve(Label, :title, 'urgente')
        expect(result).to eq(value: 'urgente template Clínica Co', renamed: true)
        expect(Label.new(title: result[:value], color: '#fff')).to be_valid
      end

      it 'numbers the plain suffix when it is taken too' do
        Label.create!(title: 'urgente template clínica co', color: '#fff')
        expect(resolver.resolve(Label, :title, 'urgente')[:value]).to eq('urgente template Clínica Co 2')
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
