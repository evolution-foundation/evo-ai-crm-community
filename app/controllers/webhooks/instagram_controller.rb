class Webhooks::InstagramController < ActionController::API
  include MetaTokenVerifyConcern
  include MetaWebhookSignatureConcern

  before_action :verify_meta_signature!, only: :events

  def events
    Rails.logger.info('Instagram webhook received events')
    Rails.logger.info("Instagram webhook params object: #{params['object'].inspect}")

    entries = params.to_unsafe_hash[:entry]

    if params['object'].to_s.casecmp('instagram').zero? && valid_entries?(entries)
      Rails.logger.info("Instagram webhook entry count: #{entries.length}")
      # Log full entry structure for debugging
      params[:entry]&.each_with_index do |entry, idx|
        Rails.logger.info("Instagram webhook entry[#{idx}]: id=#{entry[:id]}, time=#{entry[:time]}")
        Rails.logger.info("Instagram webhook entry[#{idx}] messaging count: #{entry[:messaging]&.length || 0}")
        entry[:messaging]&.each_with_index do |msg, msg_idx|
          Rails.logger.info("Instagram webhook entry[#{idx}] messaging[#{msg_idx}] keys: #{msg.keys.inspect}")
          Rails.logger.info("Instagram webhook entry[#{idx}] messaging[#{msg_idx}] has sender: #{msg[:sender].present?}, has recipient: #{msg[:recipient].present?}, has message: #{msg[:message].present?}")

          # Log sender and recipient IDs for verification
          if msg[:sender].present?
            Rails.logger.info("Instagram webhook entry[#{idx}] messaging[#{msg_idx}] SENDER ID: #{msg[:sender][:id]}")
          end
          if msg[:recipient].present?
            Rails.logger.info("Instagram webhook entry[#{idx}] messaging[#{msg_idx}] RECIPIENT ID: #{msg[:recipient][:id]}")
          end
        end
      end

      ::Webhooks::InstagramEventsJob.perform_later(entries)
      render json: :ok
    else
      Rails.logger.warn("Instagram webhook refused: unexpected envelope (object=#{params['object'].to_s[0, 40].inspect})")
      head :unprocessable_entity
    end
  end

  private

  def meta_app_secret_keys
    # INSTAGRAM_APP_SECRET is the app of direct Instagram login; FB_APP_SECRET the app of the
    # Facebook page the Instagram account is linked to. Meta signs with the one that owns the webhook.
    %w[INSTAGRAM_APP_SECRET FB_APP_SECRET]
  end

  def valid_entries?(entries)
    entries.is_a?(Array) && entries.all?(Hash)
  end

  def valid_token?(token)
    # Both configs default to '', so a blank token would match an unconfigured channel.
    return false if token.blank?

    # IG_VERIFY_TOKEN is the Instagram channel via a Facebook page;
    # INSTAGRAM_VERIFY_TOKEN is the channel via direct Instagram login.
    token == GlobalConfigService.load('IG_VERIFY_TOKEN', '') ||
      token == GlobalConfigService.load('INSTAGRAM_VERIFY_TOKEN', '')
  end
end
