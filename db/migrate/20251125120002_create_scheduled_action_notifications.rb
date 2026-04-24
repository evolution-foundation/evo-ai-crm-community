# frozen_string_literal: true

class CreateScheduledActionNotifications < ActiveRecord::Migration[7.0]
  def change
    create_table :scheduled_action_notifications do |t|
      t.bigint :scheduled_action_id, null: false
      t.uuid :user_id, null: false
      t.string :notification_type, null: false, limit: 20  # 'success', 'failure', 'retry'
      t.string :status, null: false, default: 'pending', limit: 20  # 'pending', 'sent', 'failed'
      t.text :message
      t.text :error_details

      t.timestamps
    end

    add_index :scheduled_action_notifications, :scheduled_action_id
    add_index :scheduled_action_notifications, :user_id
    add_index :scheduled_action_notifications, :notification_type
    add_index :scheduled_action_notifications, :status
    add_index :scheduled_action_notifications, [:user_id, :created_at], name: 'idx_notifications_user_date'
    add_index :scheduled_action_notifications, [:scheduled_action_id, :notification_type], name: 'idx_notifications_action_type'

    add_foreign_key :scheduled_action_notifications, :scheduled_actions, on_delete: :cascade
  end
end
