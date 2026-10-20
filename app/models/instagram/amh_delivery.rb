# frozen_string_literal: true

class Instagram::AmhDelivery < ApplicationRecord
  self.table_name = 'instagram_amh_deliveries'
  belongs_to :inbound_event, class_name: 'Instagram::AmhInboundEvent'
  belongs_to :proof, class_name: 'Instagram::AmhVisualProof'

  def snapshot
    as_json(only: %i[id version_id state prompt_state reason created_at updated_at prompt_accepted_at confirmation_received_at])
  end
end
