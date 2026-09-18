# frozen_string_literal: true

# Resolves which AI credential is in effect for a given feature. The ONLY owner
# of the precedence rule: the core stores the scope but resolves no inheritance.
#
# Scopes are an ordered chain, most specific wins. A list and not a pair on
# purpose — the enterprise overlay inserts an `agency` link by adding to the
# chain, never by rewriting resolution, so there is no `if account then ...
# else installation` here.
#
# `account:` is threaded rather than queried: this CRM is single-tenant and has
# no accounts table. The parameter exists for that overlay to scope a link.
class Ai::CredentialResolver
  # Key and endpoint travel together: an OpenAI-compatible provider is the pair,
  # so a key from one credential with a URL from elsewhere hits the wrong server.
  # `base_url` nil means "use the consumer's default".
  Endpoint = Struct.new(:key, :base_url, keyword_init: true)

  # Consumers an admin can explicitly pin to one credential, and the config
  # key each pin is read from. Scoped to consumers that actually have a
  # settings page to put the picker on — ai_agents already has its own
  # per-agent credential selection elsewhere, and label_suggestion/moderation
  # have no settings page at all today.
  PINNED_CREDENTIAL_CONFIG_KEYS = {
    inbox_assist: 'INBOX_ASSIST_CREDENTIAL_ID',
    audio_transcription: 'AUDIO_TRANSCRIPTION_CREDENTIAL_ID',
    knowledge_embedding: 'KNOWLEDGE_EMBEDDING_CREDENTIAL_ID',
    memory_compression: 'MEMORY_COMPRESSION_CREDENTIAL_ID'
  }.freeze

  # Returns the credential record in effect, or nil when no link in the chain
  # offers a usable one. Never raises for "nothing configured" — that is an
  # expected state.
  def self.resolve(for_consumer:, account: nil)
    new(consumer: for_consumer, account: account).resolve
  end

  # Returns the plaintext key in effect, decrypting the registry value or
  # falling back to the legacy sources. This is what consumers call.
  # `legacy_hook` is the caller's own openai Hook when it has one, so the
  # fallback reads the same record the consumer used before this story.
  def self.resolve_key(for_consumer:, account: nil, legacy_hook: nil)
    resolve_endpoint(for_consumer: for_consumer, account: account, legacy_hook: legacy_hook).key
  end

  # Returns the Endpoint in effect. Callers that need both halves must use this
  # rather than pairing `resolve_key` with a URL of their own.
  def self.resolve_endpoint(for_consumer:, account: nil, legacy_hook: nil)
    new(consumer: for_consumer, account: account, legacy_hook: legacy_hook).resolve_endpoint
  end

  def initialize(consumer:, account: nil, legacy_hook: nil)
    @consumer = consumer&.to_sym
    @account = account
    @legacy_hook = legacy_hook
  end

  def resolve
    return nil unless Ai::ConsumerCompatibility.known?(@consumer)

    pinned = pinned_credential
    return pinned if pinned

    # Most specific first: Ai::ScopeChain reads the chain backwards, so
    # inserting a link changes precedence without touching this method.
    Ai::ScopeChain.resolve { |scope| credential_for(scope) }
  end

  def resolve_key
    resolve_endpoint.key
  end

  def resolve_endpoint
    credential = resolve
    key = credential && Ai::CredentialDecryptor.decrypt(credential.key)
    return Endpoint.new(key: key, base_url: credential.base_url.presence) if key.present?

    # The legacy sources hold a key and nothing else: the endpoint there has
    # always been the consumer's own OPENAI_API_URL, and nil keeps it that way.
    Endpoint.new(key: legacy_key, base_url: nil)
  end

  private

  # LEGACY FALLBACK, alive only while Ai::MigrationState says this installation
  # still keeps its key in the old sources. Once the migration has run — or
  # there was never anything to migrate — the registry is the single origin.
  #
  # It lives inside the resolver and was never spread across consumers.
  def legacy_key
    return nil unless Ai::ConsumerCompatibility.accepts?(@consumer, 'openai')
    return nil unless Ai::MigrationState.legacy_fallback_active?(legacy_hook: @legacy_hook)

    global_key = GlobalConfigService.load('OPENAI_API_SECRET', nil)
    if global_key.present?
      Ai::MigrationState.warn_pending_migration
      return global_key
    end

    hook_key = legacy_hook_key
    Ai::MigrationState.warn_pending_migration if hook_key.present?
    hook_key
  rescue StandardError => e
    Rails.logger.error("Ai::CredentialResolver legacy fallback: #{e.class}: #{e.message}")
    nil
  end

  # Consumers holding a Hook pass it in, so the fallback reads the very record
  # they read before. Without one, the account-level openai hook is used.
  def legacy_hook_key
    hook = @legacy_hook || Integrations::Hook.find_by(app_id: 'openai')
    hook&.settings&.dig('api_key').presence
  end

  def pinned_credential
    config_key = PINNED_CREDENTIAL_CONFIG_KEYS[@consumer]
    return nil unless config_key

    pinned_id = GlobalConfigService.load(config_key, nil)
    return nil if pinned_id.blank?

    credential = Ai::Credential.active.find_by(id: pinned_id)
    return nil unless credential && accepted?(credential)

    credential
  rescue ActiveRecord::StatementInvalid
    # A malformed (non-UUID) pinned id must degrade to "no pin", not raise —
    # an admin-entered value should never be able to break every AI feature
    # that reads through this resolver.
    nil
  end

  def credential_for(scope)
    candidates(scope).find { |credential| accepted?(credential) }
  end

  def candidates(scope)
    Ai::Credential
      .active
      .for_scope(scope.to_s)
      .order(created_at: :asc)
  end

  # A credential the consumer cannot speak to is skipped, so resolution falls
  # through to a more generic link instead of failing at the provider (FR18).
  # An empty `allowed_consumers` means unrestricted, the behavior every
  # credential had before this column existed.
  def accepted?(credential)
    return false unless Ai::ConsumerCompatibility.accepts?(@consumer, credential.provider)

    allowed = credential.allowed_consumers
    allowed.blank? || allowed.include?(@consumer.to_s)
  end
end
