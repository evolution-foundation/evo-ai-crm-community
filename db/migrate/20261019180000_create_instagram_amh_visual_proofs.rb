class CreateInstagramAmhVisualProofs < ActiveRecord::Migration[7.1]
  def change
    create_table :instagram_amh_visual_proofs, id: :uuid do |t|
      t.uuid :create_key, null: false
      t.string :name, null: false
      t.jsonb :draft, null: false, default: {}
      t.jsonb :versions, null: false, default: []
      t.jsonb :ledger, null: false, default: []
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :instagram_amh_visual_proofs, :create_key, unique: true
  end
end
