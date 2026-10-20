# frozen_string_literal: true

class Instagram::AmhConfirmationToken
  PREFIX = 'AMH_CONFIRM_V1:'
  PURPOSE = 'instagram_amh_confirmation'

  def self.verifier
    ActiveSupport::MessageVerifier.new(Rails.application.key_generator.generate_key(PURPOSE, 32),
                                      digest: 'SHA256', serializer: JSON, url_safe: true)
  end

  def self.issue(delivery)
    PREFIX + verifier.generate({ 'delivery_id' => delivery.id }, expires_in: 7.days, purpose: PURPOSE)
  end

  def self.read(payload)
    return unless payload.is_a?(String) && payload.bytesize <= 1000 && payload.start_with?(PREFIX)

    verifier.verified(payload.delete_prefix(PREFIX), purpose: PURPOSE)&.fetch('delivery_id', nil)
  end
end
