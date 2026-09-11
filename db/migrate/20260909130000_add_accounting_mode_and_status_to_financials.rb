# frozen_string_literal: true

class AddAccountingModeAndStatusToFinancials < ActiveRecord::Migration[7.1]
  def change
    add_column :recurring_transactions, :accounting_mode, :string, default: 'automatic', null: false
    add_index :recurring_transactions, :accounting_mode

    add_column :financial_transactions, :status, :string, default: 'confirmed', null: false
    add_column :financial_transactions, :confirmed_at, :datetime
    add_index :financial_transactions, :status

    reversible do |dir|
      dir.up do
        execute "UPDATE financial_transactions SET confirmed_at = created_at WHERE status = 'confirmed'"
      end
    end
  end
end
