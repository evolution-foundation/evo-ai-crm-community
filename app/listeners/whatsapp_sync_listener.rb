# frozen_string_literal: true

class WhatsappSyncListener < BaseListener
  def inbox_created(event)
    inbox = event.data[:inbox]

    Rails.logger.info "[WHATSAPP_SYNC_LISTENER] INBOX_CREATED event received for inbox: #{inbox.name} (ID: #{inbox.id})"
    Rails.logger.info "[WHATSAPP_SYNC_LISTENER] Channel type: #{inbox.channel_type}"

    unless whatsapp_channel?(inbox)
      Rails.logger.info '[WHATSAPP_SYNC_LISTENER] Skipping - not a WhatsApp channel'
      return
    end

    Rails.logger.info "[WHATSAPP_SYNC_LISTENER] Channel provider: #{inbox.channel&.provider}"

    unless sync_enabled?(inbox)
      Rails.logger.info '[WHATSAPP_SYNC_LISTENER] Skipping - sync not enabled'
      return
    end

    Rails.logger.info "[WHATSAPP_SYNC_LISTENER] ✅ All conditions met! Triggering WhatsappSyncInitiatorJob for inbox: #{inbox.id}"

    # Trigger sync initialization in background job
    WhatsappSyncInitiatorJob.perform_later(inbox.id)
  end

  private

  def whatsapp_channel?(inbox)
    is_whatsapp = inbox.channel_type == 'Channel::Whatsapp'
    Rails.logger.info "[WHATSAPP_SYNC_LISTENER] WhatsApp channel check: #{is_whatsapp}"
    is_whatsapp
  end

  def sync_enabled?(inbox)
    channel = inbox.channel
    provider_config = channel.provider_config || {}

    sync_enabled = case channel.provider
                   when 'whatsapp_cloud'
                     whatsapp_cloud_sync_enabled?(provider_config)
                   when 'evolution'
                     evolution_sync_enabled?(provider_config)
                   when 'evolution_go'
                     evolution_go_sync_enabled?(provider_config)
                   else
                     false
                   end

    Rails.logger.info "[WHATSAPP_SYNC_LISTENER] Sync enabled check for #{channel.provider}: #{sync_enabled}"
    Rails.logger.info "[WHATSAPP_SYNC_LISTENER] Provider config keys: #{provider_config.to_h.keys.inspect}"

    sync_enabled
  end

  def whatsapp_cloud_sync_enabled?(provider_config)
    # For WhatsApp Cloud, sync is enabled if embedded signup was used with sync features
    provider_config['enable_sync_features'] == true
  end

  def evolution_sync_enabled?(provider_config)
    # For Evolution, sync is enabled if explicitly configured
    provider_config['enable_sync_features'] == true
  end

  def evolution_go_sync_enabled?(provider_config)
    # For Evolution Go, sync is enabled if explicitly configured
    provider_config['enable_sync_features'] == true
  end
end
