# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Templates::IdRemapper' do
    it 'has service spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

require_relative '../../../app/services/templates/id_remapper'

RSpec.describe Templates::IdRemapper do
  let(:remapper) { described_class.new }

  describe '#register and #resolve' do
    it 'maps slug to id within a category' do
      remapper.register('labels', 'urgente', 'uuid-1')
      expect(remapper.resolve('labels', 'urgente')).to eq('uuid-1')
    end

    it 'isolates categories' do
      remapper.register('labels', 'urgente', 'uuid-1')
      remapper.register('teams', 'urgente', 'uuid-2')
      expect(remapper.resolve('labels', 'urgente')).to eq('uuid-1')
      expect(remapper.resolve('teams', 'urgente')).to eq('uuid-2')
    end

    it 'returns nil for unknown slugs' do
      expect(remapper.resolve('labels', 'nope')).to be_nil
    end

    it 'raises on blank slug at register' do
      expect { remapper.register('labels', '', 'uuid') }.to raise_error(ArgumentError)
    end
  end

  describe '#resolve_many' do
    it 'returns only resolved ids, skipping unknown' do
      remapper.register('labels', 'a', 'uuid-a')
      remapper.register('labels', 'b', 'uuid-b')
      expect(remapper.resolve_many('labels', %w[a b unknown])).to eq(%w[uuid-a uuid-b])
    end
  end

  describe '.slug_for' do
    it 'lowercases and kebab-cases' do
      expect(described_class.slug_for('Vendas Clínica')).to eq('vendas-cl-nica')
    end

    it 'handles special chars and trim hyphens' do
      expect(described_class.slug_for('  Foo Bar! ')).to eq('foo-bar')
    end

    it 'returns "item" for empty input' do
      expect(described_class.slug_for('!!!')).to eq('item')
    end
  end
end
