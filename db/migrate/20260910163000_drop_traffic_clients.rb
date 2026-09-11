# Reverte 20260910160000_create_traffic_clients — a lista solta de clientes
# de tráfego foi descartada em favor de Metas de Clientes
# (Marketing::ClientGoal), que já cobre o cadastro de cliente vinculado a
# contas de anúncio.
class DropTrafficClients < ActiveRecord::Migration[7.1]
  def change
    drop_table :traffic_clients, if_exists: true
  end
end
