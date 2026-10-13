# frozen_string_literal: true

# Answers whether this installation has moved its integration secrets into the
# vault, which is what keeps the inline fallback from being cut on an install
# that never migrated — there, every bot, tool and MCP resolves to nothing.
#
# Migrated means the task recorded it ran (the one signal a real delete cannot
# undo), a credential still carries `imported_from` (installs migrated before the
# record), or nothing is left inline (a fresh install).
class Ai::IntegrationMigrationState
  MIGRATED_FLAG = 'INTEGRATION_CREDENTIALS_MIGRATED'

  class << self
    def migrated?
      migration_recorded? || imported_credentials? || legacy_sources_empty?
    end

    # The fallback stays alive exactly while the guard says we are not migrated.
    def legacy_fallback_active?
      !migrated?
    end

    def migration_recorded?
      Ai::MigrationRecord.recorded?(MIGRATED_FLAG)
    end

    def record_migration!
      Ai::MigrationRecord.record!(MIGRATED_FLAG)
    end

    # Backfill for installs migrated before the record: records what the imported
    # rows still prove and imports nothing, so an unlinked bot stays unlinked.
    def record_existing_migration!
      return false unless imported_credentials?

      record_migration!
      true
    end

    def imported_credentials?
      Ai::IntegrationCredential.where.not(imported_from: nil).exists?
    rescue StandardError => e
      # A missing table or a database hiccup must not read as "migrated": that
      # would remove the fallback on a broken install.
      Rails.logger.error("Ai::IntegrationMigrationState: #{e.class}: #{e.message}")
      false
    end

    # EVERY store the migration touches, not just bots: an installation whose
    # inline secret lives in a Dify integration and has no bots would otherwise
    # answer "migrated" and lose the credential it still authenticates with.
    def legacy_sources_empty?
      pending_bots.zero? && pending_integrations.zero?
    rescue StandardError => e
      # A database hiccup must not read as "migrated": that would remove the
      # fallback on a broken install.
      Rails.logger.error("Ai::IntegrationMigrationState: #{e.class}: #{e.message}")
      false
    end

    def pending_bots
      AgentBot.where(credential_id: nil)
              .where.not(api_key: [nil, ''])
              .count
    end

    # An integration still holding a static secret inline, with no vault
    # reference replacing it. Tools and MCP servers live in tables the core owns
    # and are counted by the Go endpoint; here we cover what Rails can see.
    def pending_integrations
      return 0 unless Ai::AgentIntegration.table_exists?

      Ai::AgentIntegration
        .static_providers
        .where("config ->> 'credential_id' IS NULL")
        .where("COALESCE(config ->> 'apiKey', config ->> 'nexus_api_key', config ->> 'basicAuthPass', '') <> ''")
        .count
    end
  end
end
