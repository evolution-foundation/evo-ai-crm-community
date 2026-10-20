# https://docs.360dialog.com/whatsapp-api/whatsapp-api/media
# https://developers.facebook.com/docs/whatsapp/api/media/

class Whatsapp::IncomingMessageWhatsappCloudService < Whatsapp::IncomingMessageBaseService
  def perform
    inbox.channel.with_lock { super }
  end

  private

  def find_message_by_source_id(id)
    @message = inbox.messages.find_by(source_id: id) if id
  end

  # Cloud processing is serialized by the channel row lock, including retries.
  def message_under_process? = false
  def cache_message_source_id_in_redis; end
  def clear_message_source_id_from_redis; end

  def set_contact
    value = processed_params
    if value[:contacts].blank? && value[:messages]&.first&.dig(:from).present?
      sender = value[:messages].first[:from]
      key = sender.match?(/\A\+?\d+\z/) ? :wa_id : :user_id
      value[:contacts] = [{ key => sender }.with_indifferent_access]
    end
    super
  end

  def set_conversation
    return super unless params[:observed]

    conversations = @contact_inbox.conversations
    conversations = conversations.where.not(status: :resolved) unless inbox.lock_to_single_conversation
    @conversation = conversations.last || conversations.create!(inbox: inbox, contact: @contact, source: :imported)
  end

  def create_message(message)
    super
    return unless params[:observed]

    @message.source = :imported
    @message.created_at = Time.zone.at(message[:timestamp].to_i)
    @message.content_attributes = @message.content_attributes.merge(whatsapp_observed: true)
  end

  def processed_params
    @processed_params ||= params[:entry].try(:first).try(:[], 'changes').try(:first).try(:[], 'value')
  end

  def download_attachment_file(attachment_payload)
    url_response = HTTParty.get(inbox.channel.media_url(attachment_payload[:id]), headers: inbox.channel.api_headers)
    # This url response will be failure if the access token has expired.
    inbox.channel.authorization_error! if url_response.unauthorized?
    Down.download(url_response.parsed_response['url'], headers: inbox.channel.api_headers) if url_response.success?
  end
end
