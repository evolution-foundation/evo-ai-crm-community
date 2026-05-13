# frozen_string_literal: true

class AddIndexToContactsType < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    add_index :contacts, :type,
              name: 'index_contacts_on_type',
              algorithm: :concurrently,
              if_not_exists: true
  end
end
