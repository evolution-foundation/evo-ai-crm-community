# frozen_string_literal: true

class AddInstagramAmhConfirmation < ActiveRecord::Migration[7.1]
  def change
    add_column :instagram_amh_deliveries, :prompt_state, :string, null: false, default: 'pending'
    add_column :instagram_amh_deliveries, :encrypted_prompt_receipt, :text
    add_column :instagram_amh_deliveries, :prompt_accepted_at, :datetime
    add_column :instagram_amh_deliveries, :prompt_expires_at, :datetime
    add_column :instagram_amh_deliveries, :confirmation_received_at, :datetime
    add_reference :instagram_amh_deliveries, :confirmation_event, type: :uuid,
                  foreign_key: { to_table: :instagram_amh_inbound_events }, index: { unique: true }
  end
end
