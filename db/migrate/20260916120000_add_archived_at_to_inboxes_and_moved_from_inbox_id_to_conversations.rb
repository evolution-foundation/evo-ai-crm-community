class AddArchivedAtToInboxesAndMovedFromInboxIdToConversations < ActiveRecord::Migration[7.1]
  def change
    add_column :inboxes, :archived_at, :datetime
    add_index :inboxes, :archived_at

    add_column :conversations, :moved_from_inbox_id, :uuid
    add_index :conversations, :moved_from_inbox_id
    add_foreign_key :conversations, :inboxes, column: :moved_from_inbox_id
  end
end
