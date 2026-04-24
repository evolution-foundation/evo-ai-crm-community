# frozen_string_literal: true

class CreateScheduledActions < ActiveRecord::Migration[7.0]
  def change
    create_table :scheduled_actions do |t|
      t.bigint :deal_id
      t.uuid :contact_id
      t.uuid :conversation_id
      t.string :action_type, null: false, limit: 50
      t.string :status, null: false, default: 'scheduled', limit: 20
      t.datetime :scheduled_for, null: false
      t.datetime :executed_at
      t.jsonb :payload, null: false, default: {}
      t.bigint :template_id
      t.uuid :created_by, null: false
      t.integer :retry_count, default: 0
      t.integer :max_retries, default: 3
      t.text :error_message
      t.string :recurrence_type, limit: 20
      t.jsonb :recurrence_config, default: {}

      t.timestamps
    end

    add_index :scheduled_actions, :deal_id
    add_index :scheduled_actions, :contact_id
    add_index :scheduled_actions, :conversation_id
    add_index :scheduled_actions, :scheduled_for
    add_index :scheduled_actions, :status
    add_index :scheduled_actions, :action_type
    add_index :scheduled_actions, [:status, :scheduled_for], name: 'idx_scheduled_actions_status_time'
    add_index :scheduled_actions, [:deal_id, :status], name: 'idx_scheduled_actions_deal_status'
    add_index :scheduled_actions, [:contact_id, :status], name: 'idx_scheduled_actions_contact_status'

    add_foreign_key :scheduled_actions, :contacts, on_delete: :cascade
    add_foreign_key :scheduled_actions, :conversations, on_delete: :cascade
  end
end

