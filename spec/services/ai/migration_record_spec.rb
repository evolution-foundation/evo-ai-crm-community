# frozen_string_literal: true

require 'rails_helper'

# The record is what keeps a migrated install migrated once its imported
# credentials are deleted, for both the AI keys and the integration secrets.
RSpec.describe Ai::MigrationRecord do
  [Ai::MigrationState::MIGRATED_FLAG, Ai::IntegrationMigrationState::MIGRATED_FLAG].each do |flag|
    context "with #{flag}" do
      before { InstallationConfig.where(name: flag).delete_all }

      it 'is not recorded until something records it' do
        expect(described_class.recorded?(flag)).to be(false)
      end

      it 'is recorded once recorded' do
        described_class.record!(flag)

        expect(described_class.recorded?(flag)).to be(true)
      end

      it 'only counts a record holding true' do
        InstallationConfig.create!(name: flag, value: false)

        expect(described_class.recorded?(flag)).to be(false)
      end

      it 'does not read the string "false" as recorded' do
        InstallationConfig.create!(name: flag, value: 'false')

        expect(described_class.recorded?(flag)).to be(false)
      end

      it 'ignores an env var with the record name' do
        stub_const('ENV', ENV.to_h.merge(flag => 'true'))

        expect(described_class.recorded?(flag)).to be(false)
      end

      it 'treats a failure reading it as NOT recorded' do
        allow(InstallationConfig).to receive(:find_by).and_raise(ActiveRecord::StatementInvalid, 'boom')

        expect(described_class.recorded?(flag)).to be(false)
      end

      it 'writes a single locked row however often it is recorded' do
        2.times { described_class.record!(flag) }

        records = InstallationConfig.where(name: flag)
        expect(records.count).to eq(1)
        expect(records.first).to have_attributes(value: true, locked: true)
      end
    end
  end

  it 'keeps the two records apart' do
    InstallationConfig.where(name: [Ai::MigrationState::MIGRATED_FLAG,
                                    Ai::IntegrationMigrationState::MIGRATED_FLAG]).delete_all

    Ai::MigrationState.record_migration!

    expect(Ai::MigrationState.migration_recorded?).to be(true)
    expect(Ai::IntegrationMigrationState.migration_recorded?).to be(false)
  end
end
