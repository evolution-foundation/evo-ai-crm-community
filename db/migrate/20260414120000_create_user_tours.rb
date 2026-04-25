class CreateUserTours < ActiveRecord::Migration[7.1]
  def change
    return if table_exists?(:user_tours)

    create_table :user_tours do |t|
      t.uuid :user_id, null: false
      t.string :tour_key, null: false
      t.string :status, null: false, default: 'completed'
      t.datetime :completed_at
      t.timestamps
    end

    add_index :user_tours, [:user_id, :tour_key], unique: true
    add_index :user_tours, :user_id
  end
end
