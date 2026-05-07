class AddGroupToContactTypeEnum < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    execute <<-SQL
      ALTER TYPE contact_type_enum ADD VALUE IF NOT EXISTS 'group';
    SQL

    # ALTER TYPE ADD VALUE cannot be used inside a transaction in PostgreSQL.
    # disable_ddl_transaction! runs this migration outside a transaction, so the
    # new enum value is committed before the UPDATE below tries to use it.
    execute <<-SQL
      UPDATE contacts SET type = 'group'
      WHERE type = 'person' AND identifier ILIKE '%@g.us';
    SQL
  end

  def down
    execute <<-SQL
      UPDATE contacts SET type = 'person' WHERE type = 'group';
    SQL
  end
end
