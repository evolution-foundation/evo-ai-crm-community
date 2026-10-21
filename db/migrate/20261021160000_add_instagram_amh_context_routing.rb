# frozen_string_literal: true

class AddInstagramAmhContextRouting < ActiveRecord::Migration[7.1]
  def change
    add_column :instagram_amh_inbound_events, :encrypted_routing_context, :text
    add_column :instagram_amh_deliveries, :resolved_material, :string
    add_column :instagram_amh_deliveries, :routing_source, :string
    add_column :instagram_amh_deliveries, :public_reply_variant, :integer
  end
end
