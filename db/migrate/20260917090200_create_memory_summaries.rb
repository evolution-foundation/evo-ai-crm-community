class CreateMemorySummaries < ActiveRecord::Migration[7.0]
  def change
    create_table :memory_summaries, id: :uuid do |t|
      t.string :app_name, null: false
      t.string :user_id, null: false
      t.text :content, null: false
      t.integer :source_event_count, null: false, default: 0
      t.timestamps
    end

    add_index :memory_summaries, [:app_name, :user_id, :created_at]
  end
end
