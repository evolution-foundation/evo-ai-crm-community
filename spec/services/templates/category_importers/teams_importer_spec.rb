# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Templates::CategoryImporters::TeamsImporter do
  let(:user) { User.create!(name: 'Admin', email: "admin-#{SecureRandom.hex(4)}@example.com") }

  def import(items)
    described_class.new(items, id_remapper: Templates::IdRemapper.new,
                               conflict_resolver: Templates::ConflictResolver.new('Clínica'),
                               current_user: user).import!
  end

  before { Team.create!(name: 'Suporte') }

  it 'renames a name that differs only in case instead of failing' do
    report = import([{ 'slug' => 'suporte', 'name' => 'suporte' }])
    expect(report.first).to include('status' => 'renamed', 'new_name' => 'suporte (Template Clínica)')
    expect(Team.find(report.first['new_id']).name).to eq('suporte (Template Clínica)')
  end
end
