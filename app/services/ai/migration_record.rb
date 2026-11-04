# frozen_string_literal: true

# The fact that a credential migration task ran, kept in installation_configs.
# Shared by Ai::MigrationState and Ai::IntegrationMigrationState, each with its
# own flag name. Read straight from the table: GlobalConfigService would let an
# env var of the same name answer, and caches a missing key for a day.
module Ai::MigrationRecord
  module_function

  def recorded?(flag)
    InstallationConfig.find_by(name: flag)&.value == true
  rescue StandardError => e
    # Reading an error as "recorded" would remove the legacy fallback on a
    # broken install.
    Rails.logger.error("Ai::MigrationRecord(#{flag}): #{e.class}: #{e.message}")
    false
  end

  def record!(flag)
    config = InstallationConfig.find_or_initialize_by(name: flag)
    config.value = true
    config.locked = true
    config.save!
  end
end
