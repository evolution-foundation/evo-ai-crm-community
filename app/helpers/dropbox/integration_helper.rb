module Dropbox::IntegrationHelper
  # Generates a signed JWT token for Dropbox integration's OAuth `state` param
  #
  # @param identifier [String] The identifier to encode in the token
  # @return [String, nil] The encoded JWT token or nil if client secret is missing
  def generate_dropbox_token(identifier)
    return if dropbox_client_secret.blank?

    JWT.encode(dropbox_token_payload(identifier), dropbox_client_secret, 'HS256')
  rescue StandardError => e
    Rails.logger.error("Failed to generate Dropbox token: #{e.message}")
    nil
  end

  def dropbox_token_payload(identifier)
    {
      sub: identifier,
      iat: Time.current.to_i
    }
  end

  # Verifies and decodes a Dropbox JWT token
  #
  # @param token [String] The JWT token to verify
  # @return [String, nil] The identifier from the token or nil if invalid
  def verify_dropbox_token(token)
    return if token.blank? || dropbox_client_secret.blank?

    decode_dropbox_token(token, dropbox_client_secret)
  end

  private

  def dropbox_client_secret
    @dropbox_client_secret ||= GlobalConfigService.load('DROPBOX_APP_SECRET', nil)
  end

  def decode_dropbox_token(token, secret)
    JWT.decode(token, secret, true, {
                 algorithm: 'HS256',
                 verify_expiration: true
               }).first['sub']
  rescue StandardError => e
    Rails.logger.error("Unexpected error verifying Dropbox token: #{e.message}")
    nil
  end
end
