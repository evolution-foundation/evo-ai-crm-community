class CreateProcedures < ActiveRecord::Migration[7.1]
  def change
    create_table :procedures, id: :uuid, if_not_exists: true do |t|
      t.string :title, null: false
      t.text :description
      t.string :category
      t.jsonb :tags, null: false, default: []
      t.integer :status, null: false, default: 0
      t.integer :usage_mode, null: false, default: 0
      t.jsonb :content_blocks, null: false, default: []
      t.jsonb :metadata, null: false, default: {}
      t.string :public_token
      t.uuid :created_by_id
      t.uuid :updated_by_id
      t.datetime :published_at
      t.datetime :archived_at
      t.timestamps
    end

    add_index :procedures, :status, if_not_exists: true
    add_index :procedures, :usage_mode, if_not_exists: true
    add_index :procedures, :category, if_not_exists: true
    add_index :procedures, :public_token, unique: true, where: 'public_token IS NOT NULL',
              if_not_exists: true

    create_table :procedure_visibilities, id: :uuid, if_not_exists: true do |t|
      t.uuid :procedure_id, null: false
      t.string :scope_type, null: false
      t.uuid :scope_id
      t.timestamps
    end

    add_index :procedure_visibilities, :procedure_id, if_not_exists: true
    add_index :procedure_visibilities, [:scope_type, :scope_id], if_not_exists: true
    add_index :procedure_visibilities, [:procedure_id, :scope_type, :scope_id],
              unique: true, name: 'idx_procedure_visibilities_unique_scope', if_not_exists: true
    add_index :procedure_visibilities, [:procedure_id, :scope_type],
              unique: true, where: 'scope_id IS NULL',
              name: 'idx_procedure_visibilities_unique_global_scope', if_not_exists: true
    add_foreign_key :procedure_visibilities, :procedures, if_not_exists: true

    create_table :procedure_targets, id: :uuid, if_not_exists: true do |t|
      t.uuid :procedure_id, null: false
      t.string :target_type, null: false
      t.uuid :target_id, null: false
      t.timestamps
    end

    add_index :procedure_targets, :procedure_id, if_not_exists: true
    add_index :procedure_targets, [:target_type, :target_id], if_not_exists: true
    add_index :procedure_targets, [:procedure_id, :target_type, :target_id],
              unique: true, name: 'idx_procedure_targets_unique_target', if_not_exists: true
    add_foreign_key :procedure_targets, :procedures, if_not_exists: true
  end
end
