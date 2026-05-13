class CreateProducts < ActiveRecord::Migration[7.1]
  def change
    create_table :products, id: :uuid do |t|
      t.string :name, null: false, limit: 255
      t.string :slug, limit: 255
      t.string :kind, null: false, default: 'physical', limit: 20
      t.text :description
      t.string :sku, limit: 100
      t.decimal :default_price, precision: 10, scale: 2, null: false, default: 0.0
      t.string :currency, null: false, default: 'BRL', limit: 3
      t.string :purchase_url, limit: 2048
      t.string :status, null: false, default: 'active', limit: 20
      t.integer :stock_quantity
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :products, :sku, unique: true, where: 'sku IS NOT NULL'
    add_index :products, :status
    add_index :products, :kind
    add_index :products, :metadata, using: :gin

    add_check_constraint :products, "kind IN ('physical', 'digital')", name: 'products_kind_check'
    add_check_constraint :products, "status IN ('active', 'inactive', 'draft')", name: 'products_status_check'
    add_check_constraint :products, 'default_price >= 0', name: 'products_default_price_non_negative'
    add_check_constraint :products, '(stock_quantity IS NULL) OR (stock_quantity >= 0)', name: 'products_stock_quantity_non_negative'
  end
end
