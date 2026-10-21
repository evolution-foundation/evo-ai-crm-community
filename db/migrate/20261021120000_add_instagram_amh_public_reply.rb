# frozen_string_literal: true

class AddInstagramAmhPublicReply < ActiveRecord::Migration[7.1]
  def change
    add_column :instagram_amh_deliveries, :public_reply_state, :string, null: false, default: 'not_requested'
    add_column :instagram_amh_deliveries, :public_reply_reason, :string
    add_column :instagram_amh_deliveries, :encrypted_public_reply_receipt, :text
    add_column :instagram_amh_deliveries, :public_reply_requested_at, :datetime
    add_column :instagram_amh_deliveries, :public_reply_accepted_at, :datetime
  end
end
