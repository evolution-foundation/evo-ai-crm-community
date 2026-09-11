class CreateTrafficClients < ActiveRecord::Migration[7.1]
  def change
    create_table :traffic_clients, id: :uuid, if_not_exists: true do |t|
      t.string :name, null: false
      t.string :contact_name
      t.string :phone
      t.string :email
      t.boolean :active, null: false, default: true
      t.text :notes

      t.timestamps
    end

    add_index :traffic_clients, :active, if_not_exists: true
  end
end
