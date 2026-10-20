class CreateInstagramAmhShortLinks < ActiveRecord::Migration[7.1]
  def change
    create_table :instagram_amh_short_links, id: :uuid do |t|
      t.string :code_hash, null: false, limit: 64
      t.string :event_hash, null: false, limit: 64
      t.string :material, null: false
      t.string :graph_digest, null: false
      t.uuid :version_id, null: false
      t.text :encrypted_payload
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :instagram_amh_short_links, :code_hash, unique: true
    add_index :instagram_amh_short_links, :event_hash, unique: true
    add_index :instagram_amh_short_links, :expires_at
    add_check_constraint :instagram_amh_short_links, "material IN ('amh', 'amh-consultorio')", name: 'amh_short_link_material'
  end
end
