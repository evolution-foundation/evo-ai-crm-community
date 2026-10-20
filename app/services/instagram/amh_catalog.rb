# frozen_string_literal: true

# Small account-scoped inventory. Never exposes tokens, comments or identities.
class Instagram::AmhCatalog
  class Unavailable < StandardError; end

  def self.snapshot
    inbox = Instagram::AmhConnection.bound_inbox!
    channel = inbox.channel
    raise Unavailable if channel.expires_at <= Time.current

    response = HTTParty.get("https://graph.instagram.com/v23.0/#{channel.instagram_id}/media",
                            headers: { 'Authorization' => "Bearer #{channel.access_token}" },
                            query: { fields: 'id,caption,permalink,media_type', limit: 50 }, timeout: 15)
    raise Unavailable unless response.success?

    body = response.parsed_response
    raise Unavailable unless body.is_a?(Hash) && body['data'].is_a?(Array)

    publications = body['data'].first(50).map do |item|
      { id: item.fetch('id'), label: item['caption'].to_s.truncate(120), permalink: item['permalink'], source: 'instagram' }
    end
    # Ad-only media may be absent from /media. Include observed IDs without PII.
    observed = Instagram::AmhInboundEvent.where(inbox_id: inbox.id).order(created_at: :desc).limit(100).filter_map do |event|
      contract = event.contract
      next unless contract['kind'] == 'comment' && contract['media_id'].present?

      { id: contract['media_id'], label: 'Publicação com comentário recebido', source: 'received', ad: contract['ad_id'] }
    end
    { account: { id: channel.instagram_id, label: inbox.name }, publications: (publications + observed).uniq { |p| p[:id] },
      test_available: ENV.fetch('INSTAGRAM_AMH_TEST_IGSIDS', '').split(',').any?(&:present?),
      execution_available: ENV['INSTAGRAM_AMH_EXECUTION_ENABLED'] == 'true' }
  rescue Instagram::AmhConnection::ConfigurationError, Net::OpenTimeout, Net::ReadTimeout, SocketError, KeyError
    raise Unavailable
  end
end
