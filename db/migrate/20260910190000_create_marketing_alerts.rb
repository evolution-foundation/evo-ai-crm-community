# Histórico dos avisos automáticos de Marketing (relatório semanal + checagem
# diária de metas) — populado só quando o canal "notification" (aviso dentro
# do CRM) está marcado em MARKETING_ALERTS_CHANNELS. Serve de log mesmo pra
# quem usa WhatsApp/e-mail, pra conferir o que já foi enviado.
class CreateMarketingAlerts < ActiveRecord::Migration[7.1]
  def change
    create_table :marketing_alerts, id: :uuid, if_not_exists: true do |t|
      t.string :kind, null: false
      t.string :title, null: false
      t.text :body, null: false
      t.datetime :read_at

      t.timestamps
    end

    add_index :marketing_alerts, :created_at, if_not_exists: true
  end
end
