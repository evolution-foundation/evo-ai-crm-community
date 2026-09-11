class CreateMarketingGoalDailyStatuses < ActiveRecord::Migration[7.1]
  def change
    create_table :marketing_goal_daily_statuses, id: :uuid, if_not_exists: true do |t|
      t.uuid :marketing_client_goal_id, null: false
      t.string :objective_key, null: false, limit: 100
      t.date :date, null: false
      t.decimal :spend, precision: 12, scale: 2, default: 0.0
      # "results" fica decimal (não integer) pra caber o cálculo de
      # "alcance" (reach/1000, custo por mil pessoas alcançadas).
      t.decimal :results, precision: 14, scale: 4, default: 0.0
      t.decimal :cost_per_result, precision: 12, scale: 4
      # nil = objetivo sem forma de medir automaticamente pela API do Meta
      # (ex: "seguidores", "outro") — não confundir com false (calculado e
      # fora da margem).
      t.boolean :within_margin

      t.timestamps
    end

    add_index :marketing_goal_daily_statuses, %i[marketing_client_goal_id objective_key date],
              unique: true, name: 'index_goal_daily_statuses_on_goal_objective_date', if_not_exists: true
    add_foreign_key :marketing_goal_daily_statuses, :marketing_client_goals, if_not_exists: true
  end
end
