class RenameFirebaseCredentialsToSecret < ActiveRecord::Migration[7.1]
  class InstallationConfig < ActiveRecord::Base
    self.table_name = 'installation_configs'
  end

  def up
    require 'fernet'
    config = InstallationConfig.find_by(name: 'FIREBASE_CREDENTIALS')
    return unless config
    return if InstallationConfig.exists?(name: 'FIREBASE_CREDENTIALS_SECRET')

    config.update_column(:name, 'FIREBASE_CREDENTIALS_SECRET')

    # Encrypt existing plaintext value
    key = ENV.fetch('ENCRYPTION_KEY', nil)
    return unless key.present?

    val = config.serialized_value&.dig('value')
    return if val.nil? || val.to_s.blank? || val.to_s.start_with?('gAAAAA')

    config.update_column(:serialized_value, { 'value' => Fernet.generate(key, val.to_s) })
  end

  def down
    require 'fernet'
    config = InstallationConfig.find_by(name: 'FIREBASE_CREDENTIALS_SECRET')
    return unless config
    return if InstallationConfig.exists?(name: 'FIREBASE_CREDENTIALS')

    # Decrypt value before renaming back (old key name won't trigger auto-decryption)
    key = ENV.fetch('ENCRYPTION_KEY', nil)
    if key.present?
      val = config.serialized_value&.dig('value')
      if val.present? && val.to_s.start_with?('gAAAAA')
        decrypted = Fernet.verifier(key, val.to_s).message
        config.update_column(:serialized_value, { 'value' => decrypted })
      end
    end

    config.update_column(:name, 'FIREBASE_CREDENTIALS')
  end
end
