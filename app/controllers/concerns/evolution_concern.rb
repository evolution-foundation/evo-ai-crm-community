module EvolutionConcern
  extend ActiveSupport::Concern

  private

  # Resolve `api_url` for an Evolution channel, falling back to the global
  # admin config (EVOLUTION_API_URL) when the channel has an empty
  # `provider_config['api_url']` or when channel is nil (pre-creation flows).
  #
  # Accepts optional raw_params to check request params before GlobalConfig
  # (used in create actions where the channel may not exist yet).
  def evolution_api_url_for(channel, raw_params = {})
    url = channel&.provider_config&.dig('api_url').presence ||
          raw_params[:api_url].presence ||
          GlobalConfigService.load('EVOLUTION_API_URL', '').to_s.strip
    url.presence
  end

  def evolution_admin_token_for(channel, raw_params = {})
    token = channel&.provider_config&.dig('admin_token').presence ||
            raw_params[:api_hash].presence ||
            GlobalConfigService.load('EVOLUTION_ADMIN_SECRET', '').to_s.strip
    token.presence
  end

  # Resolve credentials with GlobalConfig fallback. Works for both:
  # - Existing channels (reads provider_config, falls back to GlobalConfig)
  # - Pre-creation flows where channel is nil (reads raw_params, falls back to GlobalConfig)
  #
  # Raises with a clear message when credentials are missing from all sources.
  def evolution_credentials_for!(channel, raw_params = {})
    api_url = evolution_api_url_for(channel, raw_params)
    api_hash = evolution_admin_token_for(channel, raw_params)

    if api_url.blank? || api_hash.blank?
      raise StandardError,
            'Evolution API not configured. Set api_url + admin_token on the channel, ' \
            'provide them in the request, or configure EVOLUTION_API_URL + EVOLUTION_ADMIN_SECRET globally.'
    end

    [api_url, api_hash]
  end

  # Convenience alias for controllers that pass raw_params in create actions.
  def resolve_evolution_credentials(channel, raw_params)
    evolution_credentials_for!(channel, raw_params)
  end
end
