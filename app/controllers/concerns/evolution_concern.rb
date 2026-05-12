module EvolutionConcern
  extend ActiveSupport::Concern

  private

  # Resolve `api_url` for an Evolution channel, falling back to the global
  # admin config when the channel itself was created with an empty
  # `provider_config['api_url']`.
  #
  # Why this exists: the Admin Settings page lets the operator configure the
  # Evolution API URL once (saved into GlobalConfig as `EVOLUTION_API_URL`).
  # Channels created afterwards leave `provider_config['api_url']` blank,
  # relying on the backend to fall through to the global. `Whatsapp::Providers::
  # EvolutionService` already does this fallback (see `validate_provider_config?`),
  # but several REST controllers were calling `provider_config['api_url'].chomp('/')`
  # directly and crashing with `undefined method 'chomp' for nil` whenever an
  # operator used the global flow. Using this helper everywhere keeps the
  # fallback consistent and surfaces a clear error when truly missing.
  def evolution_api_url_for(channel)
    return nil if channel.nil?

    url = channel.provider_config&.dig('api_url').presence ||
          GlobalConfigService.load('EVOLUTION_API_URL', '').to_s.strip
    url.presence
  end

  def evolution_admin_token_for(channel)
    return nil if channel.nil?

    token = channel.provider_config&.dig('admin_token').presence ||
            GlobalConfigService.load('EVOLUTION_ADMIN_SECRET', '').to_s.strip
    token.presence
  end

  # Resolve credentials for create actions where the channel may not exist yet.
  # Prefers channel-based lookup (with GlobalConfig fallback), falls back to
  # raw request params for pre-creation flows (QR code refresh, proxy set, etc.).
  def resolve_evolution_credentials(channel, raw_params)
    if channel
      evolution_credentials_for!(channel)
    else
      api_url = raw_params[:api_url].presence || GlobalConfigService.load('EVOLUTION_API_URL', '').to_s.strip
      api_hash = raw_params[:api_hash].presence || GlobalConfigService.load('EVOLUTION_ADMIN_SECRET', '').to_s.strip

      if api_url.blank? || api_hash.blank?
        raise StandardError,
              'Evolution API not configured. Provide api_url + api_hash in the request ' \
              'or configure EVOLUTION_API_URL + EVOLUTION_ADMIN_SECRET globally.'
      end

      [api_url, api_hash]
    end
  end

  # Raise if either credential is missing — the message tells the operator
  # exactly what to configure rather than leaking a `nil.chomp` stack trace.
  def evolution_credentials_for!(channel)
    api_url = evolution_api_url_for(channel)
    api_hash = evolution_admin_token_for(channel)

    if api_url.blank? || api_hash.blank?
      raise StandardError,
            'Evolution API not configured. Set api_url + admin_token on the channel ' \
            'or configure EVOLUTION_API_URL + EVOLUTION_ADMIN_SECRET globally.'
    end

    [api_url, api_hash]
  end
end
