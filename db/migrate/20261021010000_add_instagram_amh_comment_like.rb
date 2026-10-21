# frozen_string_literal: true

class AddInstagramAmhCommentLike < ActiveRecord::Migration[7.1]
  def change
    add_column :instagram_amh_deliveries, :like_state, :string, null: false, default: 'not_requested'
    add_column :instagram_amh_deliveries, :like_reason, :string
    add_column :instagram_amh_deliveries, :encrypted_like_receipt, :text
    add_column :instagram_amh_deliveries, :like_requested_at, :datetime
    add_column :instagram_amh_deliveries, :like_accepted_at, :datetime
  end
end
