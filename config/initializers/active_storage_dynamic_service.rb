# frozen_string_literal: true

# Overrides ActiveStorage::Blob.service so the storage provider chosen in Admin
# Settings → Storage is honoured at request time, not only at boot.
#
# GlobalConfigService.load reads from installation_configs via GlobalConfig
# (Redis-cached, invalidated on save via GlobalConfig.set).  Web workers and
# Sidekiq jobs both call through this path, so they converge within one cache
# cycle after the admin switches providers.
#
# Caveat: S3 credentials are still read at boot from config/storage.yml ERB —
# changing them in the UI requires a service restart.
Rails.application.config.after_initialize do
  ActiveStorage::Blob.class_eval do
    class << self
      alias_method :_static_service, :service

      def service
        service_name = GlobalConfigService.load(
          'ACTIVE_STORAGE_SERVICE',
          ENV.fetch('ACTIVE_STORAGE_SERVICE', 'local')
        ).presence || 'local'
        key = service_name.to_sym
        resolved = respond_to?(:services) && services[key]
        unless resolved
          Rails.logger.warn("[ActiveStorage] service '#{service_name}' not registered (built at boot); falling back to boot-time default")
        end
        resolved || _static_service
      rescue StandardError => e
        Rails.logger.warn("[ActiveStorage] failed to resolve dynamic service: #{e.message}; falling back to boot-time default")
        _static_service
      end
    end
  end
end
