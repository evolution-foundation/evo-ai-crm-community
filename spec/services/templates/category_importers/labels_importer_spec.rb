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
  let(:user) { User.create!(name: 'Admin', email: "admin-#{SecureRandom.hex(4)}@example.com") }
  let(:id_remapper) { Templates::IdRemapper.new }
  let(:conflict_resolver) { Templates::ConflictResolver.new('Clínica') }

  def import(items)
    described_class.new(items, id_remapper: id_remapper, conflict_resolver: conflict_resolver, current_user: user).import!
  end

  describe '#import!' do
    it 'creates labels and registers their slug' do
      report = import([{ 'slug' => 'novo-tag', 'title' => "Novo-#{SecureRandom.hex(4)}", 'color' => '#fff' }])
      expect(report.first['status']).to eq('created')
      expect(id_remapper.resolve('labels', 'novo-tag')).to eq(report.first['new_id'])
    end

    it 'renames on collision to a title the label format accepts' do
      Label.create!(title: 'urgente-test', color: '#aaa')
      report = import([{ 'slug' => 'u', 'title' => 'urgente-test', 'color' => '#bbb' }])
      expect(report.first).to include('status' => 'renamed', 'new_name' => 'urgente-test template Clínica')
      expect(Label.find(report.first['new_id']).title).to eq('urgente-test template clínica')
    end

    it 'renames a title that differs only in case instead of failing' do
      Label.create!(title: 'urgente-test', color: '#aaa')
      report = import([{ 'slug' => 'u', 'title' => 'Urgente-Test', 'color' => '#bbb' }])
      expect(report.first['status']).to eq('renamed')
      expect(Label.find(report.first['new_id']).title).to eq('urgente-test template clínica')
    end
  end
end
