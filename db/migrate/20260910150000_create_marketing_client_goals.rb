class CreateMarketingClientGoals < ActiveRecord::Migration[7.1]
  def change
    create_table :marketing_client_goals, id: :uuid, if_not_exists: true do |t|
      t.string :name, null: false, limit: 255
      t.string :segment, limit: 255
      # "Onde fecha venda" — canal onde a venda de fato acontece (Site,
      # WhatsApp, Loja Física, etc.), separado do objetivo do anúncio.
      t.string :sales_channel, limit: 100
      t.decimal :meta_budget, precision: 10, scale: 2, default: 0.0

      # [{ "id" => "123456", "name" => "Conta Loja X" }, ...]
      t.jsonb :ad_accounts, null: false, default: []

      # [{ "key" => uuid, "objective_type" => "mensagens", "custom_label" => nil,
      #    "budget" => 500.0,
      #    "target_result_daily"|weekly|monthly => n,
      #    "cost_margin_daily_min"|max, weekly_*, monthly_* => n }, ...]
      # `key` é gerado no model (assign_objective_keys) e é o que
      # MarketingGoalDailyStatus usa pra saber a qual objetivo pertence,
      # já que objetivos não têm linha própria no banco.
      t.jsonb :objectives, null: false, default: []

      # [{ "change_date" => "2026-09-10", "level" => "campanha", "reference_name" => "...",
      #    "description" => "..." }, ...] — log manual de mudanças
      # (conta/campanha/conjunto/anúncio) que o usuário pediu pra registrar.
      t.jsonb :changelog, null: false, default: []

      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :marketing_client_goals, :active, if_not_exists: true
    add_index :marketing_client_goals, :ad_accounts, using: :gin, if_not_exists: true
    add_index :marketing_client_goals, :objectives, using: :gin, if_not_exists: true
  end
end
