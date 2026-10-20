# frozen_string_literal: true

# Dedicated transport: recipient is a comment, never an arbitrary profile ID.
# No automatic retries: a network failure can mean the provider accepted the DM.
class Instagram::AmhPrivateReply
  Result = Struct.new(:state, :reason, :receipt, keyword_init: true)

  def self.call(channel:, comment_id:, text:)
    response = HTTParty.post("https://graph.instagram.com/v23.0/#{channel.instagram_id}/messages",
                             headers: { 'Authorization' => "Bearer #{channel.access_token}", 'Content-Type' => 'application/json' },
                             body: JSON.generate(recipient: { comment_id: comment_id }, message: { text: text }), timeout: 20)
    body = response.parsed_response
    if response.success? && body.is_a?(Hash) && body['message_id'].present?
      Result.new(state: 'accepted', reason: 'provider_accepted', receipt: body.slice('message_id', 'recipient_id'))
    elsif response.code >= 500 || response.success?
      Result.new(state: 'uncertain', reason: 'provider_result_unknown')
    else
      # Store only numeric error metadata; provider text can contain private data.
      Result.new(state: 'failed', reason: "provider_#{response.code}", receipt: { code: body.is_a?(Hash) ? body.dig('error', 'code') : nil })
    end
  rescue StandardError
    Result.new(state: 'uncertain', reason: 'transport_result_unknown')
  end
end
