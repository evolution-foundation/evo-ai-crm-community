# Cliente pode pertencer a mais de um segmento ao mesmo tempo (ex: uma
# hamburgueria que também faz eventos) — troca a coluna `segment` (string
# única) por `segments` (array). Migra o valor já existente pro array antes
# de remover a coluna antiga.
class ConvertSegmentToSegmentsArray < ActiveRecord::Migration[7.1]
  class MigrationClientGoal < ActiveRecord::Base
    self.table_name = 'marketing_client_goals'
  end

  def up
    add_column :marketing_client_goals, :segments, :jsonb, null: false, default: []

    MigrationClientGoal.reset_column_information
    MigrationClientGoal.find_each do |goal|
      next if goal.segment.blank?

      goal.update_column(:segments, [goal.segment])
    end

    remove_column :marketing_client_goals, :segment, :string
  end

  def down
    add_column :marketing_client_goals, :segment, :string, limit: 255

    MigrationClientGoal.reset_column_information
    MigrationClientGoal.find_each do |goal|
      next if Array(goal.segments).empty?

      goal.update_column(:segment, Array(goal.segments).first)
    end

    remove_column :marketing_client_goals, :segments, :jsonb
  end
end
