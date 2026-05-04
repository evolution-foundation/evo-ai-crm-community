class OptimizeContactsPerformance < ActiveRecord::Migration[7.0]
  def up
    # Index to speed up the subquery used in Contact.resolved_contacts
    execute <<-SQL
      CREATE INDEX idx_contact_inboxes_contact_id
      ON contact_inboxes (contact_id)
      WHERE contact_id IS NOT NULL;
    SQL

    # Partial index for contacts that have at least one identifier (email, phone, or identifier)
    execute <<-SQL
      CREATE INDEX idx_contacts_with_identity
      ON contacts (id)
      WHERE (email <> '' OR phone_number <> '' OR identifier <> '');
    SQL

    # Composite index for common ordering and filtering by name/type on resolved contacts
    execute <<-SQL
      CREATE INDEX idx_contacts_name_type_resolved
      ON contacts (name, type, id)
      WHERE (email <> '' OR phone_number <> '' OR identifier <> '');
    SQL
  end

  def down
    remove_index :contact_inboxes, name: :idx_contact_inboxes_contact_id rescue nil
    remove_index :contacts, name: :idx_contacts_with_identity rescue nil
    remove_index :contacts, name: :idx_contacts_name_type_resolved rescue nil
  end
end
