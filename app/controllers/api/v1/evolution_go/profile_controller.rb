class Api::V1::EvolutionGo::ProfileController < Api::V1::BaseController
  before_action :set_instance_params, only: [:show, :info, :avatar, :update_picture, :update_name, :update_status,
                                             :update_picture_by_instance, :remove_picture]

  # GET USER INFO - POST /user/info
  def info
    Rails.logger.info "Evolution Go API: Getting user info for instance #{@instance_uuid}"

    if @api_url.blank? || @instance_token.blank?
      return render json: {
        error: 'Missing required parameters: api_url, instance_token'
      }, status: :bad_request
    end

    # Get phone numbers from params
    phone_numbers = params[:numbers] || params[:number] || []
    phone_numbers = [phone_numbers] unless phone_numbers.is_a?(Array)

    if phone_numbers.empty?
      return render json: {
        error: 'Missing required parameter: numbers (array of phone numbers)'
      }, status: :bad_request
    end

    begin
      user_info = get_user_info(@api_url, @instance_token, phone_numbers)

      render json: {
        success: true,
        message: 'User info retrieved successfully',
        data: user_info
      }
    rescue StandardError => e
      Rails.logger.error "Evolution Go API: Get user info error: #{e.message}"
      render json: {
        error: e.message
      }, status: :unprocessable_entity
    end
  end

  # GET AVATAR - POST /user/avatar
  def avatar
    Rails.logger.info "Evolution Go API: Getting avatar for instance #{@instance_uuid}"

    if @api_url.blank? || @instance_token.blank?
      return render json: {
        error: 'Missing required parameters: api_url, instance_token'
      }, status: :bad_request
    end

    phone_number = params[:number]
    preview = params[:preview] || false

    if phone_number.blank?
      return render json: {
        error: 'Missing required parameter: number (phone number)'
      }, status: :bad_request
    end

    begin
      avatar_data = get_avatar(@api_url, @instance_token, phone_number, preview)

      render json: {
        success: true,
        message: 'Avatar retrieved successfully',
        data: avatar_data
      }
    rescue StandardError => e
      Rails.logger.error "Evolution Go API: Get avatar error: #{e.message}"
      render json: {
        error: e.message
      }, status: :unprocessable_entity
    end
  end

  # UPDATE PROFILE PICTURE - POST /user/profilePicture
  def update_picture
    Rails.logger.info "Evolution Go API: Updating profile picture for instance #{@instance_uuid}"

    if @api_url.blank? || @instance_token.blank?
      return render json: {
        error: 'Missing required parameters: api_url, instance_token'
      }, status: :bad_request
    end

    image_url = params[:image]

    if image_url.blank?
      return render json: {
        error: 'Missing required parameter: image (URL of the image)'
      }, status: :bad_request
    end

    begin
      result = update_profile_picture(@api_url, @instance_token, image_url)

      render json: {
        success: true,
        message: 'Profile picture updated successfully',
        data: result
      }
    rescue StandardError => e
      Rails.logger.error "Evolution Go API: Update profile picture error: #{e.message}"
      render json: {
        error: e.message
      }, status: :unprocessable_entity
    end
  end

  # GET PROFILE - fetches current profile name/status from instance
  def show
    Rails.logger.info "Evolution Go API: Getting profile for instance #{@instance_uuid}"

    if @api_url.blank? || @instance_token.blank?
      return render json: { error: 'Missing required parameters' }, status: :bad_request
    end

    begin
      result = fetch_profile(@api_url, @instance_token)

      render json: {
        success: true,
        data: result
      }
    rescue StandardError => e
      Rails.logger.error "Evolution Go API: Get profile error: #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  # UPDATE PROFILE NAME - POST /user/profileName
  def update_name
    Rails.logger.info "Evolution Go API: Updating profile name for instance #{@instance_uuid}"

    if @api_url.blank? || @instance_token.blank?
      return render json: { error: 'Missing required parameters' }, status: :bad_request
    end

    name = params[:name]
    if name.blank?
      return render json: { error: 'Missing required parameter: name' }, status: :bad_request
    end

    begin
      result = set_profile_name(@api_url, @instance_token, name)
      render json: { success: true, message: 'Profile name updated successfully', data: result }
    rescue StandardError => e
      Rails.logger.error "Evolution Go API: Update profile name error: #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  # UPDATE PROFILE STATUS - POST /user/profileStatus
  def update_status
    Rails.logger.info "Evolution Go API: Updating profile status for instance #{@instance_uuid}"

    if @api_url.blank? || @instance_token.blank?
      return render json: { error: 'Missing required parameters' }, status: :bad_request
    end

    status = params[:status]
    if status.blank?
      return render json: { error: 'Missing required parameter: status' }, status: :bad_request
    end

    begin
      result = set_profile_status(@api_url, @instance_token, status)
      render json: { success: true, message: 'Profile status updated successfully', data: result }
    rescue StandardError => e
      Rails.logger.error "Evolution Go API: Update profile status error: #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  # UPDATE PROFILE PICTURE by instance ID - POST /user/profilePicture
  def update_picture_by_instance
    Rails.logger.info "Evolution Go API: Updating profile picture for instance #{@instance_uuid}"

    if @api_url.blank? || @instance_token.blank?
      return render json: { error: 'Missing required parameters' }, status: :bad_request
    end

    image_url = params[:picture] || params[:image]
    if image_url.blank?
      return render json: { error: 'Missing required parameter: picture' }, status: :bad_request
    end

    begin
      result = update_profile_picture(@api_url, @instance_token, image_url)
      render json: { success: true, message: 'Profile picture updated successfully', data: result }
    rescue StandardError => e
      Rails.logger.error "Evolution Go API: Update profile picture error: #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  # REMOVE PROFILE PICTURE - DELETE /user/profilePicture
  def remove_picture
    Rails.logger.info "Evolution Go API: Removing profile picture for instance #{@instance_uuid}"

    if @api_url.blank? || @instance_token.blank?
      return render json: { error: 'Missing required parameters' }, status: :bad_request
    end

    begin
      result = delete_profile_picture(@api_url, @instance_token)
      render json: { success: true, message: 'Profile picture removed successfully', data: result }
    rescue StandardError => e
      Rails.logger.error "Evolution Go API: Remove profile picture error: #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  private

  def set_instance_params
    # Primeiro tenta pegar o instance_uuid da URL (params[:id])
    @instance_uuid = params[:id] || params[:instance_uuid] || params[:instanceId]

    # Se instance_uuid não está na URL, busca nos params
    if @instance_uuid.blank?
      @instance_uuid = params[:instance_uuid] || params[:instanceId]
    end

    # Busca diretamente pelo Channel::Whatsapp para evitar problemas com associação polimórfica
    whatsapp_channel = Channel::Whatsapp.joins(:inbox)
                                        .where(provider: 'evolution_go')
                                        .where('provider_config @> ?', { instance_uuid: @instance_uuid }.to_json)
                                        .first

    if whatsapp_channel
      @inbox = whatsapp_channel.inbox
      @api_url = whatsapp_channel.provider_config['api_url']
      @admin_token = whatsapp_channel.provider_config['admin_token']
      @instance_token = whatsapp_channel.provider_config['instance_token']
    else
      # Fallback para parâmetros diretos (para compatibilidade)
      @api_url = params[:api_url]
      @admin_token = params[:admin_token]
      @instance_token = params[:instance_token]
    end
  end

  def get_user_info(api_url, instance_token, phone_numbers)
    info_url = "#{api_url.chomp('/')}/user/info"
    Rails.logger.info "Evolution Go API: Getting user info at #{info_url} for numbers: #{phone_numbers.join(', ')}"

    uri = URI.parse(info_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Post.new(uri)
    request['apikey'] = instance_token
    request['Content-Type'] = 'application/json'
    request.body = { number: phone_numbers }.to_json

    Rails.logger.info "Evolution Go API: User info request body: #{request.body}"

    response = http.request(request)
    Rails.logger.info "Evolution Go API: User info response code: #{response.code}"
    Rails.logger.info "Evolution Go API: User info response body: #{response.body}"

    raise "Failed to get user info. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution Go API: User info JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution Go API user info endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution Go API: User info connection error: #{e.class} - #{e.message}"
    raise "Failed to get user info: #{e.message}"
  end

  def get_avatar(api_url, instance_token, phone_number, preview)
    avatar_url = "#{api_url.chomp('/')}/user/avatar"
    Rails.logger.info "Evolution Go API: Getting avatar at #{avatar_url} for number: #{phone_number}"

    uri = URI.parse(avatar_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Post.new(uri)
    request['apikey'] = instance_token
    request['Content-Type'] = 'application/json'
    request.body = {
      number: phone_number,
      preview: preview
    }.to_json

    Rails.logger.info "Evolution Go API: Avatar request body: #{request.body}"

    response = http.request(request)
    Rails.logger.info "Evolution Go API: Avatar response code: #{response.code}"
    Rails.logger.info "Evolution Go API: Avatar response body: #{response.body[0..200]}" # First 200 chars

    raise "Failed to get avatar. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution Go API: Avatar JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution Go API avatar endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution Go API: Avatar connection error: #{e.class} - #{e.message}"
    raise "Failed to get avatar: #{e.message}"
  end

  def fetch_profile(api_url, instance_token)
    # Use /user/info to get own profile by passing the instance JID
    # First get instance info to find JID
    info_url = "#{api_url.chomp('/')}/instance/info/#{@instance_uuid}"
    uri = URI.parse(info_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 10
    http.read_timeout = 10

    request = Net::HTTP::Get.new(uri)
    request['apikey'] = instance_token
    request['Content-Type'] = 'application/json'

    response = http.request(request)
    instance_data = JSON.parse(response.body)
    jid = instance_data.dig('data', 'jid') || ''
    name = instance_data.dig('data', 'name') || ''

    { profileName: name, jid: jid }
  end

  def set_profile_name(api_url, instance_token, name)
    url = "#{api_url.chomp('/')}/user/profileName"
    make_post_request(url, instance_token, { name: name })
  end

  def set_profile_status(api_url, instance_token, status)
    url = "#{api_url.chomp('/')}/user/profileStatus"
    make_post_request(url, instance_token, { status: status })
  end

  def delete_profile_picture(api_url, instance_token)
    url = "#{api_url.chomp('/')}/user/profilePicture"
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Delete.new(uri)
    request['apikey'] = instance_token
    request['Content-Type'] = 'application/json'

    response = http.request(request)
    raise "Failed to remove profile picture. Status: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError
    { success: true }
  end

  def make_post_request(url, instance_token, body)
    Rails.logger.info "Evolution Go API: POST #{url}"
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Post.new(uri)
    request['apikey'] = instance_token
    request['Content-Type'] = 'application/json'
    request.body = body.to_json

    response = http.request(request)
    Rails.logger.info "Evolution Go API: Response code: #{response.code}"

    raise "Request failed. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError
    { success: true }
  end

  def update_profile_picture(api_url, instance_token, image_url)
    picture_url = "#{api_url.chomp('/')}/user/profilePicture"
    Rails.logger.info "Evolution Go API: Updating profile picture at #{picture_url}"

    uri = URI.parse(picture_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Post.new(uri)
    request['apikey'] = instance_token
    request['Content-Type'] = 'application/json'
    request.body = { image: image_url }.to_json

    Rails.logger.info "Evolution Go API: Update picture request body: #{request.body}"

    response = http.request(request)
    Rails.logger.info "Evolution Go API: Update picture response code: #{response.code}"
    Rails.logger.info "Evolution Go API: Update picture response body: #{response.body}"

    raise "Failed to update profile picture. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution Go API: Update picture JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution Go API update picture endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution Go API: Update picture connection error: #{e.class} - #{e.message}"
    raise "Failed to update profile picture: #{e.message}"
  end
end
