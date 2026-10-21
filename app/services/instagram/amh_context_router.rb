# frozen_string_literal: true

# Exact inventory IDs first; explicit subject/material phrases in captions as fallback.
class Instagram::AmhContextRouter
  Unavailable = Instagram::AmhExecutor::Unavailable

  def self.prepare!(event, inbox, version)
    event.with_lock do
      context = load_context(event) || { 'decisions' => {} }
      next if context.fetch('decisions', {}).key?(version['id'])

      material = version['graph']['nodes'].find { |n| n['id'] == 'material' }['data']
      choice = Instagram::AmhMaterialInventory.match(event.contract, material.fetch('mappings'))
      unless choice
        context.merge!(fetch_context(event, inbox)) unless context.key?('caption')
        choice = resolve_terms(context.fetch('caption'), material.fetch('routes'))
      end
      context['decisions'][version['id']] = { 'material' => choice.first, 'source' => choice.last }
      event.update!(encrypted_routing_context: Instagram::AmhInboundEvent.encryptor.encrypt_and_sign(context))
    end
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, ActiveSupport::MessageEncryptor::InvalidMessage
    raise Unavailable
  end

  def self.load_context(event)
    return if event.encrypted_routing_context.blank?

    Instagram::AmhInboundEvent.encryptor.decrypt_and_verify(event.encrypted_routing_context)
  end

  def self.fetch_context(event, inbox)
    media = event.contract['media_id']
    raise Unavailable unless media.is_a?(String) && /\A[0-9]{1,64}\z/.match?(media)

    response = HTTParty.get("https://graph.instagram.com/v23.0/#{media}",
                            headers: { 'Authorization' => "Bearer #{inbox.channel.access_token}" },
                            query: { fields: 'id,caption' }, timeout: 10)
    body = response.parsed_response
    raise Unavailable unless response.success? && body.is_a?(Hash) && body['id'] == media && body['caption'].is_a?(String)

    { 'media' => media, 'caption' => body['caption'][0, 2200], 'fetched_at' => Time.current.iso8601 }
  end

  def self.resolve(event, material, version)
    return [material.fetch('material'), 'configured'] unless material['mode'] == 'context'

    decision = load_context(event).fetch('decisions').fetch(version['id'])
    raise Unavailable unless Instagram::AmhVisualEngine::MATERIALS.include?(decision['material'])

    [decision.fetch('material'), decision.fetch('source')]
  rescue ActiveSupport::MessageEncryptor::InvalidMessage, TypeError, KeyError, NoMethodError
    raise Unavailable
  end

  def self.resolve_terms(caption, routes)
    candidates = routes.filter_map do |route|
      rule = { 'keywords' => route['keywords'], 'mode' => 'word', 'ignoreCase' => true, 'ignoreAccents' => true }
      route['material'] if Instagram::AmhVisualEngine.matches?(caption, rule)
    end.uniq
    raise Unavailable unless candidates.one?

    [candidates.first, 'publication_context']
  end
end
