class CreatePipelineTasks < ActiveRecord::Migration[7.0]
  def change
    create_table :pipeline_tasks, id: :uuid do |t|
      t.references :pipeline_item, type: :uuid, null: false, foreign_key: true
      t.uuid :created_by_id, null: false
      t.uuid :assigned_to_id

      t.string :title, null: false, limit: 255
      t.text :description

      t.datetime :due_date

      t.integer :task_type, default: 0, null: false
      # call: 0, email: 1, meeting: 2, follow_up: 3, note: 4, other: 5

      t.integer :status, default: 0, null: false
      # pending: 0, completed: 1, cancelled: 2, overdue: 3

      t.integer :priority, default: 0, null: false
      # low: 0, medium: 1, high: 2, urgent: 3

      # Tracking
      t.datetime :completed_at
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :pipeline_tasks, [:pipeline_item_id, :status]
    add_index :pipeline_tasks, [:assigned_to_id, :status, :due_date]
    add_index :pipeline_tasks, :created_by_id
    add_index :pipeline_tasks, [:due_date]
    add_index :pipeline_tasks, [:status, :due_date], where: "status = 0", name: 'index_pipeline_tasks_on_pending_status_and_due_date'
  end
end
