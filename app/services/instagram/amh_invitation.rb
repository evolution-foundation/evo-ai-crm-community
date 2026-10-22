# frozen_string_literal: true

# Only the explicitly supported token is interpolated; profile text is never code.
class Instagram::AmhInvitation
  TOKEN = '{{primeiro_nome}}'

  def self.first_name(value)
    return '' unless value.is_a?(String) && value.valid_encoding?

    word = value.unicode_normalize(:nfc).strip.split(/[[:space:]]+/).first.to_s
    return '' unless word.length.between?(1, 80) && /\A\p{L}[\p{L}\p{M}'’\-]*\z/u.match?(word)

    word.downcase.sub(/\A\p{L}/u, &:upcase)
  end

  def self.render(text:, contract:, inbox:)
    return text unless text.include?(TOKEN)

    name = first_name(contract['display_name'])
    name = first_name(profile_name(contract, inbox)) if name.empty?
    name = '' if text.gsub(TOKEN, name).bytesize > 1000
    rendered = text.gsub(TOKEN, name)
    # The standard greeting remains natural when Meta does not expose a name.
    rendered = rendered.gsub(/Oi,\s*!/i, 'Oi!') if name.empty?
    rendered
  end

  def self.profile_name(contract, inbox)
    response = HTTParty.get("https://graph.instagram.com/v23.0/#{contract.dig('identity', 'igsid')}",
                            headers: { 'Authorization' => "Bearer #{inbox.channel.access_token}" },
                            query: { fields: 'name' }, timeout: 5)
    body = response.parsed_response
    body['name'] if response.success? && body.is_a?(Hash)
  rescue StandardError
    nil
  end
  private_class_method :profile_name
end
