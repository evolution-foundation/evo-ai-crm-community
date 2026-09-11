# Objetivos passam a viver DENTRO de cada conta de anúncio
# (ad_accounts[i]['objectives']), não mais soltos num array separado no
# nível do cliente — contas diferentes do mesmo cliente podem ter metas
# diferentes entre si. Migra os poucos registros já existentes (o recurso é
# novo) movendo os objetivos soltos pra dentro da primeira conta cadastrada,
# depois remove a coluna antiga.
class MoveObjectivesIntoAdAccounts < ActiveRecord::Migration[7.1]
  class MigrationClientGoal < ActiveRecord::Base
    self.table_name = 'marketing_client_goals'
  end

  def up
    MigrationClientGoal.reset_column_information
    MigrationClientGoal.find_each do |goal|
      objectives = goal.objectives || []
      next if objectives.empty?

      accounts = goal.ad_accounts || []
      next if accounts.empty?

      accounts[0] = accounts[0].merge('objectives' => (accounts[0]['objectives'] || []) + objectives)
      goal.update_column(:ad_accounts, accounts)
    end

    remove_column :marketing_client_goals, :objectives, :jsonb
  end

  def down
    add_column :marketing_client_goals, :objectives, :jsonb, null: false, default: []
  end
end
