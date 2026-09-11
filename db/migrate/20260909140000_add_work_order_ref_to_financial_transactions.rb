# frozen_string_literal: true

class AddWorkOrderRefToFinancialTransactions < ActiveRecord::Migration[7.1]
  def change
    add_column :financial_transactions, :work_order_id, :uuid
    add_index :financial_transactions, :work_order_id, unique: true
  end
end
