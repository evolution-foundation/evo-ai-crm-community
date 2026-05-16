require 'rails_helper'
require_relative '../../db/migrate/20251117132621_add_type_to_contacts'

RSpec.describe AddTypeToContacts, type: :migration do
  let(:migration) { described_class.new }

  describe '#up' do
    it 'adds type column to contacts' do
      migration.up

      expect(ActiveRecord::Base.connection.column_exists?(:contacts, :type)).to be true
    end

    it 'creates contact_type_enum type' do
      migration.up

      types = ActiveRecord::Base.connection.query('SELECT unnest(enum_range(NULL::contact_type_enum))')
      expect(types.flatten).to match_array(['person', 'company'])
    end

    it 'sets default value to person' do
      migration.up

      column = ActiveRecord::Base.connection.columns(:contacts).find { |c| c.name == 'type' }
      expect(column.default).to eq('person')
    end

    it 'creates index on type column' do
      migration.up

      expect(ActiveRecord::Base.connection.index_exists?(:contacts, :type)).to be true
    end

    it 'backfills idx_contacts_name_type_resolved index' do
      migration.up

      expect(ActiveRecord::Base.connection.index_exists?(
        :contacts,
        %i[name type id],
        name: 'idx_contacts_name_type_resolved',
        where: "(email <> '' OR phone_number <> '' OR identifier <> '')"
      )).to be true
    end
  end

  describe '#down' do
    before do
      migration.up
    end

    it 'removes type column' do
      migration.down

      expect(ActiveRecord::Base.connection.column_exists?(:contacts, :type)).to be false
    end

    it 'drops contact_type_enum type' do
      migration.down

      expect {
        ActiveRecord::Base.connection.query('SELECT unnest(enum_range(NULL::contact_type_enum))')
      }.to raise_error(ActiveRecord::StatementInvalid, /type "contact_type_enum" does not exist/)
    end
  end
end
