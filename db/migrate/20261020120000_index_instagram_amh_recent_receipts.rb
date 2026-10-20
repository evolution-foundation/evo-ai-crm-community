# frozen_string_literal: true

class IndexInstagramAmhRecentReceipts < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    add_index :instagram_amh_inbound_events, %i[inbox_id created_at id],
              name: 'index_instagram_amh_inbox_recent', algorithm: :concurrently
  end
end
