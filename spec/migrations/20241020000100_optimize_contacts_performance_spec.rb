require 'rails_helper'
require_relative '../../db/migrate/20241020000100_optimize_contacts_performance'

RSpec.describe OptimizeContactsPerformance, type: :migration do
  let(:migration) { described_class.new }

  describe '#up' do
    it 'creates idx_contact_inboxes_contact_id partial index' do
      migration.up

      expect(ActiveRecord::Base.connection.index_exists?(
        :contact_inboxes,
        :contact_id,
        name: 'idx_contact_inboxes_contact_id',
        where: 'contact_id IS NOT NULL'
      )).to be true
    end

    it 'creates idx_contacts_with_identity partial index' do
      migration.up

      expect(ActiveRecord::Base.connection.index_exists?(
        :contacts,
        :id,
        name: 'idx_contacts_with_identity',
        where: "(email <> '' OR phone_number <> '' OR identifier <> '')"
      )).to be true
    end

    context 'when contacts.type column does not exist' do
      before do
        # Ensure type column doesn't exist
        ActiveRecord::Base.connection.remove_column(:contacts, :type) if ActiveRecord::Base.connection.column_exists?(:contacts, :type)
      end

      it 'skips creating idx_contacts_name_type_resolved without error' do
        expect { migration.up }.not_to raise_error
      end
    end

    context 'when contacts.type column exists' do
      before do
        # Add type column if it doesn't exist
        unless ActiveRecord::Base.connection.column_exists?(:contacts, :type)
          ActiveRecord::Base.connection.add_column(:contacts, :type, :string)
        end
      end

      after do
        ActiveRecord::Base.connection.remove_column(:contacts, :type) if ActiveRecord::Base.connection.column_exists?(:contacts, :type)
      end

      it 'creates idx_contacts_name_type_resolved composite index' do
        migration.up

        expect(ActiveRecord::Base.connection.index_exists?(
          :contacts,
          %i[name type id],
          name: 'idx_contacts_name_type_resolved',
          where: "(email <> '' OR phone_number <> '' OR identifier <> '')"
        )).to be true
      end
    end
  end

  describe '#down' do
    before do
      migration.up
    end

    it 'removes all created indexes' do
      migration.down

      expect(ActiveRecord::Base.connection.index_exists?(
        :contact_inboxes,
        :contact_id,
        name: 'idx_contact_inboxes_contact_id'
      )).to be false

      expect(ActiveRecord::Base.connection.index_exists?(
        :contacts,
        :id,
        name: 'idx_contacts_with_identity'
      )).to be false
    end
  end
end
