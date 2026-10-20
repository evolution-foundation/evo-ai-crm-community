# frozen_string_literal: true

class Instagram::AmhPrivateReply
  Result = Struct.new(:state, :reason, :receipt, keyword_init: true)

  # First private reply contains only the invitation. No material URL or link.
  def self.prompt(channel:, comment_id:, text:, payload:)
    request(channel: channel, recipient: { comment_id: comment_id },
            message: { text: text, quick_replies: [{ content_type: 'text', title: 'Pode enviar', payload: payload }] })
  end

  # Called only after a signed, identity-bound quick reply/postback is persisted.
  def self.deliver(channel:, recipient_id:, text:, url:, label:)
    request(channel: channel, recipient: { id: recipient_id }, message: {
              attachment: { type: 'template', payload: { template_type: 'button', text: text,
                                                        buttons: [{ type: 'web_url', url: url, title: label }] } }
            })
  end

  def self.request(channel:, recipient:, message:)
    response = HTTParty.post("https://graph.instagram.com/v23.0/#{channel.instagram_id}/messages",
                             headers: { 'Authorization' => "Bearer #{channel.access_token}", 'Content-Type' => 'application/json' },
                             body: JSON.generate(recipient: recipient, message: message), timeout: 20)
    body = response.parsed_response
    if response.success? && body.is_a?(Hash) && body['message_id'].present?
      Result.new(state: 'accepted', reason: 'provider_accepted', receipt: body.slice('message_id', 'recipient_id'))
    elsif response.code >= 500 || response.success?
      Result.new(state: 'uncertain', reason: 'provider_result_unknown')
    else
      Result.new(state: 'failed', reason: "provider_#{response.code}",
                 receipt: body.is_a?(Hash) ? body.fetch('error', {}).slice('code', 'error_subcode', 'type', 'fbtrace_id') : {})
    end
  rescue StandardError
    Result.new(state: 'uncertain', reason: 'transport_result_unknown')
  end
  private_class_method :request
end
