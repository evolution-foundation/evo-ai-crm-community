# frozen_string_literal: true

require 'digest'
require 'base64'
require 'json'

module EvoAuth
  # Resolves an auth-service token into the local User, for the HTTP layer
  # (EvoAuthConcern) and for ActionCable (RoomChannel) alike, so a subscription proves
  # identity with exactly the credential HTTP accepts. Raises ValidationError (bad
  # token) or AuthenticationError (auth unreachable); callers decide how to fail.
  class IdentityResolver
    VALIDATE_CACHE_TTL = 20.seconds
    TOKEN_TYPES = %w[bearer api_access_token].freeze
    # Breaker for an unreachable auth service. Not per token: "auth is down" is global,
    # and without it every cable retry blocks an ActionCable worker for the HTTP timeout.
    AUTH_DOWN_KEY = 'evo_auth:validate:unavailable'
    AUTH_DOWN_TTL = 5.seconds

    Identity = Struct.new(:user, :user_data, keyword_init: true)

    class << self
      def call(token:, token_type: 'bearer', auth_service: nil)
        new(token: token, token_type: token_type, auth_service: auth_service).call
      end

      def cache_key(token, token_type)
        "#{token_type}:#{Digest::SHA256.hexdigest(token.to_s)}"
      end

      def store_key(cache_key)
        "evo_auth:validate:#{cache_key}"
      end

      def find_local_user(user_data)
        return nil unless user_data

        User.from_email(user_data['email']) || User.find_by(id: user_data['id'])
      end
    end

    def initialize(token:, token_type: 'bearer', auth_service: nil)
      @token = token.to_s
      @token_type = token_type.to_s
      @auth_service = auth_service
    end

    def call
      raise EvoAuthService::ValidationError, 'Invalid token type' unless TOKEN_TYPES.include?(@token_type)
      raise EvoAuthService::ValidationError, 'Missing token' if @token.blank?

      data = user_data
      user = self.class.find_local_user(data['user'])
      raise EvoAuthService::ValidationError, 'User not found locally' unless user

      Identity.new(user: user, user_data: data)
    end

    # Cached remote validation; the per-request memo (Current) stays with the caller.
    def user_data
      key = self.class.store_key(self.class.cache_key(@token, @token_type))
      cached = Rails.cache.read(key)
      return cached if cached

      raise EvoAuthService::AuthenticationError, 'Authentication service unavailable' if Rails.cache.read(AUTH_DOWN_KEY)

      data = validate_remotely
      ttl = cache_ttl
      Rails.cache.write(key, data, expires_in: ttl) if ttl.positive?
      data
    end

    private

    def validate_remotely
      auth_service.validate_token(token: @token, token_type: @token_type)
    rescue EvoAuthService::AuthenticationError
      Rails.cache.write(AUTH_DOWN_KEY, true, expires_in: AUTH_DOWN_TTL)
      raise
    end

    def auth_service
      @auth_service ||= EvoAuthService.new
    end

    def cache_ttl
      ttl = VALIDATE_CACHE_TTL
      return ttl unless @token_type == 'bearer'

      payload = decode_jwt_payload
      return ttl unless payload.is_a?(Hash) && payload['exp'].present?

      remaining = payload['exp'].to_i - Time.now.to_i
      return 0.seconds if remaining <= 0

      [ttl, remaining.seconds].min
    rescue StandardError
      ttl
    end

    def decode_jwt_payload
      segments = @token.split('.')
      return {} if segments.length < 2

      payload_segment = segments[1]
      padding = '=' * ((4 - (payload_segment.length % 4)) % 4)
      JSON.parse(Base64.urlsafe_decode64("#{payload_segment}#{padding}"))
    rescue StandardError
      {}
    end
  end
end
