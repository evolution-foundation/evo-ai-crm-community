class Webhooks::InstagramController < ActionController::API
  include MetaTokenVerifyConcern
  before_action :receive_amh, only: :events

  def events
    Rails.logger.info('Instagram webhook received events')
    Rails.logger.info("Instagram webhook params object: #{params['object'].inspect}")
    Rails.logger.info("Instagram webhook entry count: #{params[:entry]&.length || 0}")

    if params['object'].casecmp('instagram').zero?
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

      ::Webhooks::InstagramEventsJob.perform_later(params.to_unsafe_hash[:entry])
      render json: :ok
    else
      Rails.logger.warn("Message is not received from the instagram webhook event: #{params['object']}")
      head :unprocessable_entity
    end
  end

  private

  def receive_amh
    result = Instagram::AmhIngress.new(raw: request.raw_post, signature: request.headers['X-Hub-Signature-256']).perform
    return unless result
    return head(result.status) unless result.status == 200
    return head :ok if result.remaining.empty?

    # Only the unrelated entries may enter the legacy logger/queue.
    params[:entry] = result.remaining
  end

  def valid_token?(token)
    # Validates against both IG_VERIFY_TOKEN (Instagram channel via Facebook page) and
    # INSTAGRAM_VERIFY_TOKEN (Instagram channel via direct Instagram login)
    token == GlobalConfigService.load('IG_VERIFY_TOKEN', '') ||
      token == GlobalConfigService.load('INSTAGRAM_VERIFY_TOKEN', '')
  end
end
