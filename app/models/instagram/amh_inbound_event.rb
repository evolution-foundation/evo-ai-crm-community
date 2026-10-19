# frozen_string_literal: true

class Instagram::AmhInboundEvent < ApplicationRecord
  self.table_name = 'instagram_amh_inbound_events'

  # No API serializer, callbacks, jobs or external transport. The stage 4 worker
  # will explicitly consume pending rows. Keep social metadata encrypted at rest.
  def self.encryptor
    key = Rails.application.key_generator.generate_key('instagram-amh-inbound-v1', 32)
    ActiveSupport::MessageEncryptor.new(key, cipher: 'aes-256-gcm', serializer: JSON)
  end

  def contract
    self.class.encryptor.decrypt_and_verify(encrypted_contract)
  end
end
