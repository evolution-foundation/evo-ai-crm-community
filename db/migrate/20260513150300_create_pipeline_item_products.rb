class CreatePipelineItemProducts < ActiveRecord::Migration[7.1]
  def change
    create_table :pipeline_item_products, id: :uuid do |t|
      t.references :pipeline_item, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :product, type: :uuid, null: false, foreign_key: { on_delete: :restrict }
      t.references :product_variant, type: :uuid, null: true, foreign_key: { on_delete: :restrict }
      t.integer :quantity, null: false, default: 1
      t.decimal :locked_unit_price, precision: 10, scale: 2, null: false
      t.string :currency, null: false, limit: 3
      t.text :notes
      # `created_by` is polymorphic-ish but kept loose since the creators
      # (User, AutomationRule, AiAgent) span different databases / services.
      t.string :created_by_type, limit: 50
      t.uuid :created_by_id

      t.timestamps
    end

    add_index :pipeline_item_products, [:pipeline_item_id, :product_id, :product_variant_id],
              name: 'index_pipeline_item_products_unique_combo',
              unique: false
    add_index :pipeline_item_products, [:created_by_type, :created_by_id], name: 'index_pipeline_item_products_on_creator'

    add_check_constraint :pipeline_item_products, 'quantity > 0', name: 'pipeline_item_products_quantity_positive'
    add_check_constraint :pipeline_item_products, 'locked_unit_price >= 0', name: 'pipeline_item_products_locked_unit_price_non_negative'
  end
end
