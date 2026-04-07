# frozen_string_literal: true

class DynamicOauthService
  DYNAMIC_CLIENT_PREFIX = 'dynamic_app_'.freeze

  def self.generate_dynamic_client_id(identifier = nil)
    "#{DYNAMIC_CLIENT_PREFIX}#{identifier || SecureRandom.hex(8)}"
  end

  def self.is_dynamic_client_id?(client_id)
    client_id&.start_with?(DYNAMIC_CLIENT_PREFIX)
  end

  def self.create_or_find_dynamic_application(client_id, current_user, redirect_uri = nil)
    return nil unless is_dynamic_client_id?(client_id)

    # Verify the user is an administrator
    return nil unless current_user.administrator?

    # Look for existing application by UID (client_id)
    application = Doorkeeper::Application.find_by(uid: client_id)

    # If not found, create a new application
    app_name = "Dynamic OAuth - #{current_user.name}"

    unless application
      application = Doorkeeper::Application.create!(
        name: app_name,
        uid: client_id,
        secret: generate_secret,
        redirect_uri: redirect_uri || 'urn:ietf:wg:oauth:2.0:oob',
        scopes: 'admin',
        trusted: false,
        confidential: false  # For PKCE, public application
      )
    end

    # Update redirect_uri if provided and different
    if redirect_uri && application.redirect_uri != redirect_uri
      application.update!(redirect_uri: redirect_uri)
    end

    application
  end

  def self.create_or_find_application_for_account(client_id, current_user, redirect_uri = nil)
    # Verify the user is an administrator
    return nil unless current_user.administrator?

    # Look for existing application by UID (client_id)
    application = Doorkeeper::Application.find_by(uid: client_id)

    # If application exists, ensure it is public (for PKCE)
    if application && application.confidential?
      application.update!(confidential: false)
    end

    # If not found, create new application
    app_name = "OAuth App - #{current_user.name}"

    unless application
      application = Doorkeeper::Application.create!(
        name: app_name,
        uid: client_id,
        secret: generate_secret,
        redirect_uri: redirect_uri || 'urn:ietf:wg:oauth:2.0:oob',
        scopes: 'admin',
        trusted: false
      )
    end

    # Update redirect_uri if provided and different
    if redirect_uri && application.redirect_uri != redirect_uri
      application.update!(redirect_uri: redirect_uri)
    end

    application
  end

  def self.find_application_by_client_id(client_id)
    Doorkeeper::Application.find_by(uid: client_id)
  end

  def self.available_accounts_for_user(user)
    return [] unless user

    [{
      account_name: GlobalConfigService.load('BRAND_NAME', 'Evo CRM'),
      dynamic_client_id: generate_dynamic_client_id('default')
    }]
  end

  private

  def self.generate_secret
    SecureRandom.hex(32)
  end
end
