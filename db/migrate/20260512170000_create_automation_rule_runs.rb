class CreateAutomationRuleRuns < ActiveRecord::Migration[7.1]
  def change
    create_table :automation_rule_runs, id: :uuid do |t|
      t.references :automation_rule, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :event_name, null: false
      t.string :status, null: false
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.integer :duration_ms
      t.text :error_message
      t.jsonb :payload, default: {}
      t.jsonb :steps, default: []

      t.timestamps
    end

    add_index :automation_rule_runs, [:automation_rule_id, :started_at],
              order: { started_at: :desc },
              name: 'index_automation_rule_runs_on_rule_and_started_at'
    add_index :automation_rule_runs, :started_at
    add_index :automation_rule_runs, :status
  end
end
