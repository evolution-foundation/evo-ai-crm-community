class Whatsapp::Providers::WahaService < Whatsapp::Providers::BaseService
  def send_message(phone_number, message)
    if message.attachments.present?
      send_attachment_message(phone_number, message)
    elsif message.content.present?
      send_text_message(phone_number, message)
    else
      message.update!(is_unsupported: true)
      nil
    end
  end

  def send_template(phone_number, template_info)
    Rails.logger.warn 'WAHA does not support template messages, sending as text'
    send_text_message(phone_number, template_info)
  end

  def sync_templates
    Rails.logger.debug 'WAHA: no template sync needed, templates are not supported'
  end

  def validate_provider_config?
    return false if base_url.blank?
    return false if api_key.blank?
    return false if session_name.blank?

    response = HTTParty.get("#{base_url}/api/sessions/#{session_name}", headers: api_headers, timeout: 10)
    response.success?
  rescue StandardError => e
    Rails.logger.error "WAHA validation error: #{e.message}"
    false
  end

  def check_number_exists?(phone_number)
    chat_id = to_chat_id(phone_number)
    return nil if chat_id.blank? || base_url.blank?

    response = HTTParty.post(
      "#{base_url}/api/#{session_name}/checkNumberStatus",
      headers: api_headers,
      body: { phone: chat_id.split('@').first }.to_json,
      open_timeout: 5, read_timeout: 10
    )
    return nil unless response.success?

    entry = Array(response.parsed_response).first
    return nil if entry.blank?

    ActiveModel::Type::Boolean.new.cast(entry['numberExists'])
  rescue StandardError => e
    Rails.logger.error "WAHA check_number_exists? error: #{e.class} - #{e.message}"
    nil
  end

  def disconnect_channel_provider
    return if session_name.blank? || base_url.blank?

    logout_response = HTTParty.post("#{base_url}/api/sessions/#{session_name}/logout", headers: api_headers, timeout: 30)
    Rails.logger.info "WAHA logout response: #{logout_response.code} - #{logout_response.body}"

    stop_response = HTTParty.post("#{base_url}/api/sessions/#{session_name}/stop", headers: api_headers, timeout: 30)
    Rails.logger.info "WAHA stop response: #{stop_response.code} - #{stop_response.body}"
  rescue StandardError => e
    Rails.logger.error "WAHA disconnect error: #{e.message}"
  end

  private

  def base_url
    whatsapp_channel.provider_config['base_url'].to_s.strip.chomp('/')
  end

  def api_key
    whatsapp_channel.provider_config['api_key'].to_s.strip
  end

  def session_name
    whatsapp_channel.provider_config['session_name'].to_s.strip
  end

  def api_headers
    { 'X-Api-Key' => api_key, 'Content-Type' => 'application/json' }
  end

  def to_chat_id(phone_number)
    digits = phone_number.to_s.delete('+')
    return nil if digits.blank?

    "#{digits}@c.us"
  end

  def send_text_message(phone_number, message)
    body = { session: session_name, chatId: to_chat_id(phone_number), text: html_to_whatsapp(message.content.to_s) }

    response = HTTParty.post("#{base_url}/api/sendText", headers: api_headers, body: body.to_json)
    process_waha_response(response)
  end

  def send_attachment_message(phone_number, message)
    attachment = message.attachments.first
    return unless attachment

    endpoint = case attachment.file_type
               when 'image' then 'sendImage'
               when 'audio' then 'sendVoice'
               when 'video' then 'sendVideo'
               else 'sendFile'
               end

    body = {
      session: session_name,
      chatId: to_chat_id(phone_number),
      caption: html_to_whatsapp(message.content.to_s),
      file: { url: attachment.file_url, filename: attachment.file.filename.to_s }
    }

    response = HTTParty.post("#{base_url}/api/#{endpoint}", headers: api_headers, body: body.to_json)
    process_waha_response(response)
  end

  def process_waha_response(response)
    if response.success?
      response.parsed_response['id']
    else
      handle_error(response)
      nil
    end
  end
end
