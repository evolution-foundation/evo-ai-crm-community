class CreateProductVariants < ActiveRecord::Migration[7.1]
  def change
    create_table :product_variants, id: :uuid do |t|
      t.references :product, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false, limit: 255
      t.string :sku, limit: 100
      t.decimal :price_override, precision: 10, scale: 2
      t.integer :stock_quantity
      t.jsonb :attributes_data, null: false, default: {}
      t.integer :position, null: false, default: 0

      t.timestamps
    end

    add_index :product_variants, [:product_id, :name], unique: true, name: 'index_product_variants_on_product_and_name'
    add_index :product_variants, :sku, unique: true, where: 'sku IS NOT NULL'
    add_index :product_variants, :attributes_data, using: :gin

    add_check_constraint :product_variants, '(price_override IS NULL) OR (price_override >= 0)', name: 'product_variants_price_override_non_negative'
    add_check_constraint :product_variants, '(stock_quantity IS NULL) OR (stock_quantity >= 0)', name: 'product_variants_stock_quantity_non_negative'
  end
end
