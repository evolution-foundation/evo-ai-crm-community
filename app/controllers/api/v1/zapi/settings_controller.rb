# frozen_string_literal: true

class Api::V1::Zapi::SettingsController < Api::V1::BaseController
  before_action :set_instance_params

  # GET /api/v1/zapi/settings/:instance_id
  # Retorna status e dados da instância
  def show

    begin
      if @token.blank? || @instance_id.blank?
        return render json: {
          error: 'Missing required parameters: token, instance_id'
        }, status: :bad_request
      end

      # Get instance data using /me endpoint (primary endpoint)
      # This endpoint returns instance information including connection status
      full_instance_data = nil
      status_data = nil
      instance_data = nil
      device_data = nil
      errors = []

      # Get instance data from /me endpoint first (primary endpoint)
      begin
        instance_data = get_instance_data
      rescue StandardError => e
        errors << "Instance data: #{e.message}"
        Rails.logger.warn "Z-API: Failed to get instance data: #{e.message}"
      end

      # Get status separately for connection details
      begin
        status_data = get_instance_status
      rescue StandardError => e
        errors << "Status: #{e.message}"
        Rails.logger.warn "Z-API: Failed to get status: #{e.message}"
      end

      # Try to get full instance data as fallback (GET /instances/{INSTANCE_ID})
      # This endpoint returns all instance information but may not require Client-Token
      begin
        full_instance_data = get_instance_full_data unless instance_data
      rescue StandardError => e
        errors << "Full instance data: #{e.message}"
        Rails.logger.warn "Z-API: Failed to get full instance data: #{e.message}"
      end

      # Get device data (requires connection)
      begin
        device_data = get_device_data
      rescue StandardError => e
        errors << "Device data: #{e.message}"
        Rails.logger.warn "Z-API: Failed to get device data: #{e.message}"
      end

      # Update provider_connection status based on status_data or instance_data
      update_provider_connection_status(status_data, instance_data || full_instance_data)

      # Return partial data if available, or error message if all failed
      if instance_data.nil? && full_instance_data.nil? && status_data.nil? && device_data.nil?
        error_message = if errors.any? { |e| e.include?('Client-Token') || e.include?('client-token') }
          'Some Z-API endpoints require Client-Token to be configured in your Z-API account. ' \
          'Please configure the Client-Token in your Z-API instance settings through the Z-API dashboard. ' \
          'The Client-Token is a separate token from the instance token.'
        else
          errors.join('; ')
        end

        return render json: {
          success: false,
          error: error_message,
          status: nil,
          instance: nil,
          device: nil
        }, status: :ok
      end

      render json: {
        success: true,
        status: status_data,
        instance: instance_data || full_instance_data,
        device: device_data
      }
    rescue StandardError => e
      Rails.logger.error "Z-API: Get settings error: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  # PUT /api/v1/zapi/settings/:instance_id/profile-picture
  def update_profile_picture

    begin
      image_url = params[:value] || params[:image_url]
      return render json: { error: 'Missing image URL' }, status: :bad_request if image_url.blank?

      result = update_profile_picture_api(image_url)
      render json: { success: true, data: result }
    rescue StandardError => e
      Rails.logger.error "Z-API: Update profile picture error: #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  # PUT /api/v1/zapi/settings/:instance_id/profile-name
  def update_profile_name

    begin
      name = params[:value] || params[:name]
      return render json: { error: 'Missing profile name' }, status: :bad_request if name.blank?

      result = update_profile_name_api(name)
      render json: { success: true, data: result }
    rescue StandardError => e
      Rails.logger.error "Z-API: Update profile name error: #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  # PUT /api/v1/zapi/settings/:instance_id/update-instance-name
  def update_instance_name
    begin
      name = params[:value] || params[:name]
      return render json: { error: 'Missing instance name' }, status: :bad_request if name.blank?

      result = update_instance_name_api(name)
      render json: { success: true, data: result }
    rescue StandardError => e
      Rails.logger.error "Z-API: Update instance name error: #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  # PUT /api/v1/zapi/settings/:instance_id/profile-description
  def update_profile_description

    begin
      description = params[:value] || params[:description]
      return render json: { error: 'Missing profile description' }, status: :bad_request if description.blank?

      result = update_profile_description_api(description)
      render json: { success: true, data: result }
    rescue StandardError => e
      Rails.logger.error "Z-API: Update profile description error: #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  # PUT /api/v1/zapi/settings/:instance_id/call-reject
  def update_call_reject

    begin
      reject_enabled = params[:value] || params[:reject_enabled]
      return render json: { error: 'Missing reject_enabled value' }, status: :bad_request if reject_enabled.nil?

      result = update_call_reject_api(reject_enabled)
      render json: { success: true, data: result }
    rescue StandardError => e
      Rails.logger.error "Z-API: Update call reject error: #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  # PUT /api/v1/zapi/settings/:instance_id/call-reject-message
  def update_call_reject_message

    begin
      message = params[:value] || params[:message]
      return render json: { error: 'Missing reject message' }, status: :bad_request if message.blank?

      result = update_call_reject_message_api(message)
      render json: { success: true, data: result }
    rescue StandardError => e
      Rails.logger.error "Z-API: Update call reject message error: #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/zapi/settings/:instance_id/restart
  def restart

    begin
      result = restart_instance_api
      render json: { success: true, data: result }
    rescue StandardError => e
      Rails.logger.error "Z-API: Restart instance error: #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/zapi/settings/:instance_id/disconnect
  def disconnect

    begin
      result = disconnect_instance_api
      render json: { success: true, data: result }
    rescue StandardError => e
      Rails.logger.error "Z-API: Disconnect instance error: #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  private

  def set_instance_params
    identifier = params[:id] || params[:instance_id]
    return if identifier.blank?

    whatsapp_channel = find_channel_by_instance_id(identifier)
    return unless whatsapp_channel

    @inbox = whatsapp_channel.inbox
    @api_url = 'https://api.z-api.io'
    @instance_id = whatsapp_channel.provider_config['instance_id']
    @token = whatsapp_channel.provider_config['token']
    @client_token = whatsapp_channel.provider_config['client_token']
  end

  def find_channel_by_instance_id(instance_id)
    Channel::Whatsapp.joins(:inbox)
                     .where(provider: 'zapi')
                     .where('provider_config @> ?', { instance_id: instance_id }.to_json)
                     .first
  end

  def make_api_request(endpoint, method: :put, payload: nil)
    url = "#{@api_url}/instances/#{@instance_id}/token/#{@token}/#{endpoint}"

    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = case method
              when :put
                Net::HTTP::Put.new(uri)
              when :post
                Net::HTTP::Post.new(uri)
              when :get
                Net::HTTP::Get.new(uri)
              else
                Net::HTTP::Get.new(uri)
              end

    request['Content-Type'] = 'application/json'
    request['Client-Token'] = @client_token if @client_token.present?
    request.body = payload.to_json if payload.present?

    response = http.request(request)

    # Handle 400 errors related to missing client-token more gracefully
    if response.code == '400'
      error_body = begin
        JSON.parse(response.body)
      rescue JSON::ParserError
        { 'error' => response.body }
      end

      if error_body['error']&.include?('client-token')
        Rails.logger.warn "Z-API: Endpoint #{endpoint} requires Client-Token configured in Z-API account. " \
                          "The Client-Token must be configured in the Z-API dashboard for this instance."
        raise "Client-Token must be configured in Z-API account: #{error_body['error']}. " \
              "Please configure it in your Z-API instance settings through the Z-API dashboard."
      end
    end

    raise "Failed to #{method} #{endpoint}. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Z-API: JSON parse error: #{e.message}, Body: #{response&.body}"
    raise "Invalid response from Z-API #{endpoint} endpoint"
  rescue StandardError => e
    Rails.logger.error "Z-API: Request error: #{e.class} - #{e.message}"
    raise "Failed to #{method} #{endpoint}: #{e.message}"
  end

  def get_instance_full_data
    # GET /instances/{INSTANCE_ID} - Returns all instance information
    # This endpoint doesn't require /token/{TOKEN} in the path
    url = "#{@api_url}/instances/#{@instance_id}"

    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Get.new(uri)
    request['Content-Type'] = 'application/json'
    # Add Client-Token if available (some endpoints may require it)
    request['Client-Token'] = @client_token if @client_token.present?

    response = http.request(request)

    raise "Failed to get instance data. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Z-API: JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Z-API instance endpoint'
  rescue StandardError => e
    Rails.logger.error "Z-API: Request error: #{e.class} - #{e.message}"
    raise "Failed to get instance data: #{e.message}"
  end

  def get_instance_status
    make_api_request('status', method: :get)
  end

  def get_instance_data
    make_api_request('me', method: :get)
  end

  def get_device_data
    make_api_request('device', method: :get)
  end

  def update_profile_picture_api(image_url)
    make_api_request('profile-picture', method: :put, payload: { value: image_url })
  end

  def update_profile_name_api(name)
    make_api_request('profile-name', method: :put, payload: { value: name })
  end

  def update_instance_name_api(name)
    make_api_request('update-name', method: :put, payload: { value: name })
  end

  def update_profile_description_api(description)
    make_api_request('profile-description', method: :put, payload: { value: description })
  end

  def update_call_reject_api(enabled)
    make_api_request('update-call-reject-auto', method: :put, payload: { value: enabled })
  end

  def update_call_reject_message_api(message)
    make_api_request('update-call-reject-message', method: :put, payload: { value: message })
  end

  def restart_instance_api
    make_api_request('restart', method: :get)
  end

  def disconnect_instance_api
    make_api_request('disconnect', method: :get)
  end

  # Privacy endpoints

  # GET /api/v1/zapi/settings/:instance_id/privacy_disallowed_contacts
  def privacy_disallowed_contacts
    type = params[:type] || params[:privacy_type]
    return render json: { error: 'Missing type parameter' }, status: :bad_request if type.blank?

    begin
      result = get_disallowed_contacts_api(type)
      render json: { success: true, data: result }
    rescue StandardError => e
      Rails.logger.error "Z-API: Get disallowed contacts error: #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/zapi/settings/:instance_id/privacy_set_last_seen
  def privacy_set_last_seen
    begin
      visualization_type = params[:visualization_type] || params[:visualizationType]
      contacts_blacklist = params[:contacts_blacklist] || params[:contactsBlacklist]

      payload = { visualizationType: visualization_type }
      payload[:contactsBlacklist] = contacts_blacklist if contacts_blacklist.present?

      result = set_privacy_api('last-seen', payload)
      render json: { success: true, data: result }
    rescue StandardError => e
      Rails.logger.error "Z-API: Set last seen error: #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/zapi/settings/:instance_id/privacy_set_photo_visualization
  def privacy_set_photo_visualization
    begin
      visualization_type = params[:visualization_type] || params[:visualizationType]
      contacts_blacklist = params[:contacts_blacklist] || params[:contactsBlacklist]

      payload = { visualizationType: visualization_type }
      payload[:contactsBlacklist] = contacts_blacklist if contacts_blacklist.present?

      result = set_privacy_api('photo-visualization', payload)
      render json: { success: true, data: result }
    rescue StandardError => e
      Rails.logger.error "Z-API: Set photo visualization error: #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/zapi/settings/:instance_id/privacy_set_description
  def privacy_set_description
    begin
      visualization_type = params[:visualization_type] || params[:visualizationType]
      contacts_blacklist = params[:contacts_blacklist] || params[:contactsBlacklist]

      payload = { visualizationType: visualization_type }
      payload[:contactsBlacklist] = contacts_blacklist if contacts_blacklist.present?

      result = set_privacy_api('description', payload)
      render json: { success: true, data: result }
    rescue StandardError => e
      Rails.logger.error "Z-API: Set description privacy error: #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/zapi/settings/:instance_id/privacy_set_group_add_permission
  def privacy_set_group_add_permission
    begin
      visualization_type = params[:visualization_type] || params[:visualizationType]
      contacts_blacklist = params[:contacts_blacklist] || params[:contactsBlacklist]

      payload = { visualizationType: visualization_type }
      payload[:contactsBlacklist] = contacts_blacklist if contacts_blacklist.present?

      result = set_privacy_api('group-add', payload)
      render json: { success: true, data: result }
    rescue StandardError => e
      Rails.logger.error "Z-API: Set group add permission error: #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/zapi/settings/:instance_id/privacy_set_online
  def privacy_set_online
    begin
      visualization_type = params[:visualization_type] || params[:visualizationType]
      contacts_blacklist = params[:contacts_blacklist] || params[:contactsBlacklist]

      payload = { visualizationType: visualization_type }
      payload[:contactsBlacklist] = contacts_blacklist if contacts_blacklist.present?

      result = set_privacy_api('online', payload)
      render json: { success: true, data: result }
    rescue StandardError => e
      Rails.logger.error "Z-API: Set online privacy error: #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/zapi/settings/:instance_id/privacy_set_read_receipts
  def privacy_set_read_receipts
    begin
      visualization_type = params[:visualization_type] || params[:visualizationType]
      contacts_blacklist = params[:contacts_blacklist] || params[:contactsBlacklist]

      payload = { visualizationType: visualization_type }
      payload[:contactsBlacklist] = contacts_blacklist if contacts_blacklist.present?

      result = set_privacy_api('read-receipts', payload)
      render json: { success: true, data: result }
    rescue StandardError => e
      Rails.logger.error "Z-API: Set read receipts error: #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/zapi/settings/:instance_id/privacy_set_messages_duration
  def privacy_set_messages_duration
    begin
      duration = params[:duration] || params[:value]
      return render json: { error: 'Missing duration parameter' }, status: :bad_request if duration.blank?

      result = set_messages_duration_api(duration)
      render json: { success: true, data: result }
    rescue StandardError => e
      Rails.logger.error "Z-API: Set messages duration error: #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  private

  def get_disallowed_contacts_api(type)
    url = "#{@api_url}/instances/#{@instance_id}/token/#{@token}/privacy/disallowed-contacts?type=#{type}"

    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Get.new(uri)
    request['Content-Type'] = 'application/json'
    request['Client-Token'] = @client_token if @client_token.present?

    response = http.request(request)

    raise "Failed to get disallowed contacts. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end

  def set_privacy_api(endpoint, payload)
    url = "#{@api_url}/instances/#{@instance_id}/token/#{@token}/privacy/#{endpoint}"

    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['Client-Token'] = @client_token if @client_token.present?
    request.body = payload.to_json

    response = http.request(request)

    raise "Failed to set privacy #{endpoint}. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end

  def set_messages_duration_api(duration)
    make_api_request('privacy/messages-duration', method: :post, payload: { value: duration })
  end

  def update_provider_connection_status(status_data, instance_data)
    return unless @whatsapp_channel

    # Determine connection status from status_data or instance_data
    connected = false
    error_message = nil

    if status_data.is_a?(Hash)
      # Status endpoint returns: { connected: true/false, error: "...", ... }
      connected = status_data['connected'] == true || status_data[:connected] == true
      error_message = status_data['error'] || status_data[:error]
    elsif instance_data.is_a?(Hash)
      # Instance data may have: connected, whatsappConnected, phoneConnected
      connected = instance_data['connected'] == true ||
                  instance_data[:connected] == true ||
                  instance_data['whatsappConnected'] == true ||
                  instance_data[:whatsappConnected] == true ||
                  instance_data['phoneConnected'] == true ||
                  instance_data[:phoneConnected] == true
      error_message = instance_data['error'] || instance_data[:error]
    end

    # Map connection status to provider_connection format
    connection_status = connected ? 'open' : 'close'

    # Format error message if present
    formatted_error = error_message.present? ? "Z-API: #{error_message}" : nil

    @whatsapp_channel.update_provider_connection!({
      connection: connection_status,
      error: formatted_error
    })
  rescue StandardError => e
    Rails.logger.error "Z-API: Error updating provider connection status: #{e.message}"
  end
end

