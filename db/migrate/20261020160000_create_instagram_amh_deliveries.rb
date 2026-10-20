# frozen_string_literal: true

class CreateInstagramAmhDeliveries < ActiveRecord::Migration[7.1]
  def change
    add_column :instagram_amh_visual_proofs, :active_version_id, :string
    add_column :instagram_amh_visual_proofs, :activated_at, :datetime
    add_column :instagram_amh_visual_proofs, :audience, :string, null: false, default: 'paused'
    create_table :instagram_amh_deliveries, id: :uuid do |t|
      t.references :inbound_event, type: :uuid, null: false, foreign_key: { to_table: :instagram_amh_inbound_events }, index: { unique: true }
      t.references :proof, type: :uuid, null: false, foreign_key: { to_table: :instagram_amh_visual_proofs }
      t.string :version_id, null: false
      t.string :state, null: false, default: 'pending'
      t.string :reason
      t.text :encrypted_receipt
      t.timestamps
    end
    add_index :instagram_amh_deliveries, [:state, :created_at]
  end
end
