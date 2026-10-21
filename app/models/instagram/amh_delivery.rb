# frozen_string_literal: true

class Instagram::AmhDelivery < ApplicationRecord
  self.table_name = 'instagram_amh_deliveries'
  belongs_to :inbound_event, class_name: 'Instagram::AmhInboundEvent'
  belongs_to :proof, class_name: 'Instagram::AmhVisualProof'

  def snapshot
    as_json(only: %i[id version_id state public_reply_state public_reply_reason public_reply_accepted_at prompt_state like_state like_reason like_accepted_at reason created_at updated_at prompt_accepted_at
                     confirmation_received_at])
  end
end
