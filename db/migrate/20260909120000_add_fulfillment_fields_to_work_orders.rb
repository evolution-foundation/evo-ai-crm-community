# Retirada no balcão x entrega, e — quando for entrega — qual entregador
# (motoboy próprio já cadastrado, ou uma das plataformas já integradas:
# iFood/99; Keeta ainda não tem integração nenhuma no CRM, fica só como
# rótulo até existir).
class AddFulfillmentFieldsToWorkOrders < ActiveRecord::Migration[7.1]
  def change
    add_column :work_orders, :fulfillment_type, :string, limit: 20, default: 'pickup', null: false, if_not_exists: true
    add_column :work_orders, :delivery_courier, :string, limit: 20, if_not_exists: true
    add_column :work_orders, :motoboy_id, :uuid, if_not_exists: true

    add_index :work_orders, :fulfillment_type, if_not_exists: true
    add_index :work_orders, :motoboy_id, if_not_exists: true
  end
end
