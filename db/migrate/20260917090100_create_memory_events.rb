class CreateMemoryEvents < ActiveRecord::Migration[7.0]
  def change
    create_table :memory_events, id: :uuid do |t|
      t.string :app_name, null: false
      t.string :user_id, null: false
      t.string :role, null: false
      t.text :content, null: false
      t.timestamps
    end

    add_index :memory_events, [:app_name, :user_id, :created_at]
  end
end
