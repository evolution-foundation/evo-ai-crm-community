class CreateInstagramAmhInboundEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :instagram_amh_inbound_events, id: :uuid do |t|
      t.references :inbox, type: :uuid, null: false, foreign_key: true
      t.string :event_key, limit: 64, null: false
      t.text :encrypted_contract, null: false
      t.string :state, null: false, default: 'pending'
      t.timestamps
    end
    add_index :instagram_amh_inbound_events, :event_key, unique: true
    add_index :instagram_amh_inbound_events, [:state, :created_at], name: 'index_instagram_amh_pending'
  end
end
