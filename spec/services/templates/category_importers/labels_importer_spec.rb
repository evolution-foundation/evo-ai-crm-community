# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Templates::CategoryImporters::LabelsImporter' do
    it 'has service spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Templates::CategoryImporters::LabelsImporter do
  let(:user) { User.create!(name: 'Admin', email: "admin-#{SecureRandom.hex(4)}@example.com", password: 'Password!1') }
  let(:id_remapper) { Templates::IdRemapper.new }
  let(:conflict_resolver) { Templates::ConflictResolver.new('Clínica') }

  describe '#import!' do
    it 'creates labels and registers their slug' do
      items = [{ 'slug' => 'novo-tag', 'title' => "Novo-#{SecureRandom.hex(4)}", 'color' => '#fff' }]
      report = described_class.new(items,
                                   id_remapper: id_remapper,
                                   conflict_resolver: conflict_resolver,
                                   current_user: user).import!
      expect(report.first['status']).to eq('created')
      expect(id_remapper.resolve('labels', 'novo-tag')).to eq(report.first['new_id'])
    end

    it 'renames on collision' do
      Label.create!(title: 'urgente-test', color: '#aaa')
      items = [{ 'slug' => 'u', 'title' => 'urgente-test', 'color' => '#bbb' }]
      report = described_class.new(items,
                                   id_remapper: id_remapper,
                                   conflict_resolver: conflict_resolver,
                                   current_user: user).import!
      expect(report.first['status']).to eq('renamed')
      expect(report.first['new_name']).to eq('urgente-test (Template Clínica)')
    end
  end
end
