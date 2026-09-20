# frozen_string_literal: true

# == Schema Information
#
# Table name: evo_core_api_keys
#
#  id                :uuid             not null, primary key
#  allowed_consumers :string(255)      default([]), not null, is an Array
#  is_active         :boolean          default(TRUE)
#  key               :text             not null
#  name              :string(255)      not null
#  provider          :string(255)      not null
#  created_at        :timestamptz
#  updated_at        :timestamptz
#
# Indexes
#
#  idx_evo_core_api_keys_is_active    (is_active)
#  idx_evo_core_api_keys_name         (name)
#  idx_evo_core_api_keys_name_unique  (name) UNIQUE
#
# Read-only view over `evo_core_api_keys`, the AI credential registry.
#
# evo-ai-core-service owns the table and every write; the CRM reads it directly
# because both share the `evo_community` database and the resolver runs inside
# jobs, where there is no user bearer to forward over HTTP. `readonly?` makes an
# accidental save raise rather than diverge from the schema's owner.
#
# Absent from `db/schema.rb` on purpose — Rails does not own this table.
# rubocop:disable Rails/ApplicationRecord -- ApplicationRecord adds write-path
# validations (validates_column_content_length) and event mixins that make no
# sense for a read-only view over a table another service owns.
class Ai::Credential < ActiveRecord::Base
  # rubocop:enable Rails/ApplicationRecord
  self.table_name = 'evo_core_api_keys'

  SCOPE_INSTALLATION = 'installation'
  SCOPE_ACCOUNT = 'account'

  # Providers speaking the OpenAI wire protocol, so every AI feature can use
  # them — including embeddings and audio transcription. OpenRouter joined
  # this set (not just CHAT_COMPLETIONS_COMPATIBLE_PROVIDERS below) because it
  # exposes OpenAI-shaped /embeddings and /audio/transcriptions endpoints too,
  # verified against OpenRouter's own documentation.
  OPENAI_COMPATIBLE_PROVIDERS = %w[openai azure custom custom_openai_compatible openrouter].freeze

  # Providers that speak the OpenAI chat-completions wire protocol
  # specifically — a wider set than OPENAI_COMPATIBLE_PROVIDERS, most of which
  # don't offer OpenAI-compatible embeddings or audio transcription. Mirrors
  # evo-ai-core-service-community's chatCompletionsCompatibleProviders exactly.
  CHAT_COMPLETIONS_COMPATIBLE_PROVIDERS = %w[
    openai azure custom custom_openai_compatible
    openrouter groq deepseek together_ai fireworks_ai
  ].freeze

  scope :active, -> { where(is_active: true) }
  scope :for_scope, ->(scope) { where(scope: scope) }
  scope :openai_compatible, -> { where(provider: OPENAI_COMPATIBLE_PROVIDERS) }

  # The migration writes with `insert_all!`, which bypasses instantiation, so
  # this still catches every accidental `save`/`update` on a loaded record.
  def readonly?
    true
  end

  def openai_compatible?
    OPENAI_COMPATIBLE_PROVIDERS.include?(provider)
  end
end
