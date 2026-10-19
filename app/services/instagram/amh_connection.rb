# frozen_string_literal: true

# A managed account never subscribes as a model callback. Provisioning must bind
# its reserved inbox and prove the receiver before any account subscription.
class Instagram::AmhConnection
  class ConfigurationError < StandardError; end

  class << self
    def managed_account?(id)
      target = ENV.fetch('INSTAGRAM_AMH_PROFESSIONAL_ACCOUNT_ID', '')
      target.present? && id.to_s == target
    end

    def app_id
      GlobalConfigService.load('INSTAGRAM_APP_ID', '').to_s
    end

    def reserved_id
      ENV.fetch('INSTAGRAM_AMH_RESERVED_INBOX_ID', '')
    end

    def validate!
      raise ConfigurationError, 'AMH account configuration unavailable' unless
        ENV.fetch('INSTAGRAM_AMH_PROFESSIONAL_ACCOUNT_ID', '').match?(/\A[0-9]{1,64}\z/) &&
        reserved_id.match?(/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/) &&
        Instagram::AmhSafety.inbox_ids.include?(reserved_id) &&
        app_id.present? && app_id == ENV.fetch('INSTAGRAM_AMH_APP_ID', '')
    end

    def store!(details, token)
      validate!
      id = (details['user_id'] || details['id']).to_s
      expires = validate_token!(id, token)
      ActiveRecord::Base.transaction do
        # Serialize concurrent callbacks even before the channel row exists.
        lock_key = Digest::SHA256.hexdigest(reserved_id)[0, 15].to_i(16)
        ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{lock_key})")
        persist_binding(id, token, expires)
      end
    end

    def validate_token!(id, token)
      raise ConfigurationError, 'AMH account mismatch' unless managed_account?(id)
      raise ConfigurationError, 'Pause AMH reception before provisioning' unless ENV['INSTAGRAM_AMH_RECEPTION_ENABLED'] == 'false'

      expires = Integer(token['expires_in'])
      raise ConfigurationError, 'AMH token unavailable' unless expires.between?(1, 90.days.to_i) && token['access_token'].present?

      expires
    rescue ArgumentError, TypeError
      raise ConfigurationError, 'AMH token unavailable'
    end

    def persist_binding(id, token, expires)
      channel = Channel::Instagram.find_by(instagram_id: id)
      inbox = Inbox.find_by(id: reserved_id)
      validate_binding!(channel, inbox)
      channel ||= Channel::Instagram.new(instagram_id: id)
      channel.assign_attributes(access_token: token['access_token'], expires_at: Time.current + expires.seconds, evolution_hub_meta: {})
      channel.save!
      Inbox.create!(id: reserved_id, channel: channel, name: 'Instagram AMH') unless inbox
      channel.reload
    end

    def validate_binding!(channel, inbox)
      return unless (channel&.inbox && channel.inbox.id != reserved_id) || (inbox && inbox.channel != channel)

      raise ConfigurationError, 'AMH inbox binding conflict'
    end

    def bound_inbox!
      validate!
      inbox = Inbox.find_by(id: reserved_id)
      raise ConfigurationError, 'AMH inbox unavailable' unless inbox&.channel.is_a?(Channel::Instagram) &&
                                                               managed_account?(inbox.channel[:instagram_id])

      inbox
    end
  end
end
