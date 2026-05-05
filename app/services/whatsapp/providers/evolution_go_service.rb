require 'base64'

class Whatsapp::Providers::EvolutionGoService < Whatsapp::Providers::BaseService
  def send_message(phone_number, message)
    @message = message
    @phone_number = phone_number

    if message.attachments.present?
      send_attachment_message(phone_number, message)
    elsif message.content.present?
      send_text_message(phone_number, message)
    else
      @message.update!(is_unsupported: true)
      return
    end
  end

  def send_template(phone_number, template_info)
    # Evolution Go API doesn't support template messages in the same way
    # For now, we'll send a regular text message
    Rails.logger.warn "Evolution Go API doesn't support template messages, sending as text"
    send_text_message(phone_number, build_template_text(template_info))
  end

  def sync_templates
    # Evolution Go API doesn't have template syncing like WhatsApp Cloud
    # Templates are managed internally via create_template
    Rails.logger.debug "Evolution Go: Templates are managed internally, no external sync needed"
  end

  def create_template(template_data)
    # Evolution Go doesn't have external template API
    # Store template internally in message_templates JSONB field
    Rails.logger.info "Evolution Go: Creating template internally - #{template_data['name']}"
    
    current_templates = whatsapp_channel.message_templates || []
    # Ensure current_templates is always an array (fix for existing data)
    current_templates = [] unless current_templates.is_a?(Array)
    
    # Create internal template structure
    internal_template = {
      'id' => SecureRandom.uuid,
      'name' => template_data['name'],
      'category' => template_data['category'],
      'language' => template_data['language'],
      'status' => 'APPROVED', # Evolution Go templates are always approved
      'components' => template_data['components'],
      'created_at' => Time.current.iso8601,
      'updated_at' => Time.current.iso8601
    }
    
    # Add to existing templates
    current_templates << internal_template
    
    # Templates are now stored in message_templates table, not in JSONB column
    # No need to update channel columns
    
    Rails.logger.info "Evolution Go: Template created internally with ID #{internal_template['id']}"
    internal_template
  end

  def update_template(template_id, template_data)
    Rails.logger.info "Evolution Go: Updating template internally - #{template_id}"
    
    current_templates = whatsapp_channel.message_templates || []
    # Ensure current_templates is always an array (fix for existing data)
    current_templates = [] unless current_templates.is_a?(Array)
    template_index = current_templates.find_index { |t| t['id'] == template_id }
    
    return nil unless template_index
    
    # Update existing template
    current_templates[template_index].merge!(
      'name' => template_data['name'],
      'category' => template_data['category'],
      'language' => template_data['language'],
      'components' => template_data['components'],
      'updated_at' => Time.current.iso8601
    )
    
    # Templates are now stored in message_templates table, not in JSONB column
    # No need to update channel columns
    
    Rails.logger.info "Evolution Go: Template updated internally"
    current_templates[template_index]
  end

  def delete_template(template_name)
    Rails.logger.info "Evolution Go: Deleting template internally - #{template_name}"
    
    current_templates = whatsapp_channel.message_templates || []
    # Ensure current_templates is always an array (fix for existing data)
    current_templates = [] unless current_templates.is_a?(Array)
    template_index = current_templates.find_index { |t| t['name'] == template_name }
    
    return false unless template_index
    
    # Remove template from array
    deleted_template = current_templates.delete_at(template_index)
    
    # Templates are now stored in message_templates table, not in JSONB column
    # No need to update channel columns
    
    Rails.logger.info "Evolution Go: Template deleted internally"
    true
  end

  def validate_provider_config?
    api_url = whatsapp_channel.provider_config['api_url'].presence || GlobalConfigService.load('EVOLUTION_GO_API_URL', '').to_s.strip
    admin_token = whatsapp_channel.provider_config['admin_token'].presence || GlobalConfigService.load('EVOLUTION_GO_ADMIN_SECRET', '').to_s.strip
    
    # Try multiple keys for instance name
    instance_name = whatsapp_channel.provider_config['instance_name'].presence || 
                    whatsapp_channel.provider_config['instanceName'].presence ||
                    whatsapp_channel.provider_config['name'].presence

    if api_url.blank?
      Rails.logger.error 'Evolution Go validation failed: api_url is blank'
      return false
    end

    if admin_token.blank?
      Rails.logger.error 'Evolution Go validation failed: admin_token is blank'
      return false
    end

    if instance_name.blank?
      Rails.logger.error 'Evolution Go validation failed: instance_name is blank'
      return false
    end

    Rails.logger.info 'Evolution Go validation passed'
    true
  rescue StandardError => e
    Rails.logger.error "Evolution Go validation error: #{e.message}"
    false
  end

  def api_headers
    admin_token = whatsapp_channel.provider_config['admin_token'].presence || GlobalConfigService.load('EVOLUTION_GO_ADMIN_SECRET', '').to_s.strip
    {
      'apikey' => admin_token,
      'Content-Type' => 'application/json'
    }
  end

  def instance_headers
    # Headers for sending messages - use instance token
    {
      'apikey' => whatsapp_channel.provider_config['instance_token'],
      'Content-Type' => 'application/json'
    }
  end

  def media_url(media_id)
    # Evolution Go API media endpoint
    "#{api_base_path}/media/#{media_id}"
  end

  def subscribe_to_webhooks
    # Evolution Go API webhook subscription if needed
    Rails.logger.info 'Evolution Go API webhook subscription not implemented'
  end

  def unsubscribe_from_webhooks
    # Evolution Go API webhook unsubscription if needed
    Rails.logger.info 'Evolution Go API webhook unsubscription not implemented'
  end

  def disconnect_channel_provider
    return if whatsapp_channel.provider_config['instance_uuid'].blank?

    begin
      # Logout the instance
      response = HTTParty.delete(
        "#{api_base_path}/instance/logout/#{whatsapp_channel.provider_config['instance_uuid']}",
        headers: api_headers,
        timeout: 30
      )

      Rails.logger.info "Evolution Go logout response: #{response.code} - #{response.body}"

      # Delete the instance
      delete_response = HTTParty.delete(
        "#{api_base_path}/instance/delete/#{whatsapp_channel.provider_config['instance_uuid']}",
        headers: api_headers,
        timeout: 30
      )

      Rails.logger.info "Evolution Go delete response: #{delete_response.code} - #{delete_response.body}"
    rescue StandardError => e
      Rails.logger.error "Evolution Go disconnect error: #{e.message}"
    end
  end

  private

  def api_base_path
    api_url = whatsapp_channel.provider_config['api_url'].presence || GlobalConfigService.load('EVOLUTION_GO_API_URL', '').to_s.strip
    api_url&.chomp('/')
  end

  def instance_name
    whatsapp_channel.provider_config['instance_name']
  end

  def send_text_message(phone_number, message)
    clean_number = phone_number.delete('+')
    Rails.logger.info "[Evolution Go] Sending text message to #{phone_number} (cleaned: #{clean_number})"

    # Validate Brazilian number format
    if clean_number.match?(/^55\d{2}\d{8,9}$/)
      Rails.logger.info "[Evolution Go] Valid Brazilian number format detected"
    else
      Rails.logger.warn "[Evolution Go] Number #{clean_number} may not be in valid Brazilian format (expected: 55DDNNNNNNNNN)"
    end

    body = {
      number: clean_number,
      text: html_to_whatsapp(message.respond_to?(:content) ? message.content : message.to_s),
      delay: 0
    }

    Rails.logger.info "[Evolution Go] Request body: #{body.to_json}"

    # Add quoted information if this is a reply
    quoted_info = build_quoted_info(message)
    body[:quoted] = quoted_info if quoted_info.present?

    response = HTTParty.post(
      "#{api_base_path}/send/text",
      headers: instance_headers,
      body: body.to_json
    )

    process_evolution_go_response(response)
  end

  def send_attachment_message(phone_number, message)
    attachment = message.attachments.first
    return unless attachment

    Rails.logger.info "[Evolution Go] Sending #{attachment.file_type} message to #{phone_number}"

    # Use direct S3 URL for media
    media_url = generate_direct_s3_url(attachment)

    # Map file types to Evolution Go types
    evolution_go_type = map_file_type_to_evolution_go(attachment.file_type)

    body = {
      number: phone_number.delete('+'),
      url: media_url,
      caption: html_to_whatsapp(message.content.to_s),
      filename: attachment.file.filename.to_s,
      type: evolution_go_type,
      delay: 0
    }

    # Add quoted information if this is a reply
    quoted_info = build_quoted_info(message)
    body[:quoted] = quoted_info if quoted_info.present?

    response = HTTParty.post(
      "#{api_base_path}/send/media",
      headers: instance_headers,
      body: body.to_json
    )

    process_evolution_go_response(response)
  end

  def process_evolution_go_response(response)
    if response.success?
      parsed_response = response.parsed_response

      Rails.logger.info "[Evolution Go] Send response: #{response.code} - #{response.body}"

      # Evolution Go returns: { data: { Info: { ID: "..." } }, message: "success" }
      message_id = parsed_response.dig('data', 'Info', 'ID')

      if message_id
        Rails.logger.info "[Evolution Go] Message sent successfully with ID: #{message_id}"
        return message_id
      else
        Rails.logger.warn "[Evolution Go] Message sent but no ID returned: #{parsed_response}"
        return true
      end
    end

    Rails.logger.error "[Evolution Go] Send failed: #{response.code} - #{response.body}"
    false
  end

  def map_file_type_to_evolution_go(file_type)
    case file_type
    when 'image'
      'image'
    when 'audio'
      'audio'
    when 'video'
      'video'
    when 'file'
      'document'
    else
      'document' # Default to document
    end
  end

  def generate_direct_s3_url(attachment)
    return attachment.file_url unless attachment.file.attached?

    # Always return the signed URL, never the bare object URL.
    #
    # Why: stripping the AWS signing parameters only works when the S3 bucket
    # is publicly readable. Real-world deployments (Cloudflare R2, S3 with
    # restricted ACLs, MinIO with private buckets) return XML error responses
    # to unauthenticated GETs, and Evolution Go (which downloads the URL on
    # behalf of WhatsApp) rejects the upload with:
    #   "Invalid file format: 'text/xml; charset=utf-8'. Only image/jpeg,
    #   image/png and image/webp are accepted"
    #
    # The signed URL has a short TTL (5 minutes by default) which is enough
    # for Evolution Go to fetch the media before forwarding it to WhatsApp,
    # and it carries response-content-type so the upstream sees the right
    # MIME type. Public buckets remain compatible because the signature is
    # ignored when the object is anonymously readable.
    signed_url = attachment.download_url

    Rails.logger.info "[Evolution Go S3] Using signed URL (works for both public and private buckets)"
    signed_url
  end

  def build_quoted_info(message)
    # Check if this message is a reply
    reply_to_external_id = message.content_attributes[:in_reply_to_external_id]
    return nil if reply_to_external_id.blank?

    Rails.logger.info "[Evolution Go] Message is a reply to: #{reply_to_external_id}"

    # Find the original message by source_id
    original_message = whatsapp_channel.inbox.messages.find_by(source_id: reply_to_external_id)

    unless original_message
      Rails.logger.warn "[Evolution Go] Original message not found for source_id: #{reply_to_external_id}"
      return nil
    end

    # Extract participant from original message
    participant = extract_participant_from_message(original_message)

    unless participant
      Rails.logger.warn "[Evolution Go] Could not extract participant from original message: #{original_message.id}"
      return nil
    end

    quoted_info = {
      messageId: reply_to_external_id,
      participant: participant
    }

    Rails.logger.info "[Evolution Go] Built quoted info: #{quoted_info}"
    quoted_info
  end

  def extract_participant_from_message(message)
    # For incoming messages, use the contact's phone in WhatsApp format
    if message.message_type == 'incoming' && message.sender.present?
      phone_number = message.sender.phone_number&.delete('+')
      return "#{phone_number}@s.whatsapp.net" if phone_number.present?
    end

    # For outgoing messages, use the channel's phone number
    if message.message_type == 'outgoing'
      phone_number = whatsapp_channel.phone_number&.delete('+')
      return "#{phone_number}@s.whatsapp.net" if phone_number.present?
    end

    Rails.logger.warn "[Evolution Go] Could not determine participant for message: #{message.id}"
    nil
  end
end
