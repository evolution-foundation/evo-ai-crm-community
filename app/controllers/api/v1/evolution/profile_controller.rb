class Api::V1::Evolution::ProfileController < Api::V1::BaseController
  # POST /api/v1/evolution/profile/:instance_name/fetch
  def fetch
    Rails.logger.info "Evolution API fetch profile called for instance: #{params[:instance_name]}"

    begin
      instance_name = params[:instance_name]
      phone_number = params[:number]
      provider = params[:provider] || 'evolution'

      channel = find_whatsapp_channel_by_instance_name(instance_name, provider)

      if channel
        api_url = channel.provider_config['api_url']
        api_hash = channel.provider_config['admin_token']

        result = fetch_profile(api_url, api_hash, instance_name, phone_number)

        render json: {
          success: true,
          data: result
        }
      else
        render json: { error: "Channel not found for instance: #{instance_name}" }, status: :not_found
      end
    rescue StandardError => e
      Rails.logger.error "Evolution API fetch profile error: #{e.class} - #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/evolution/profile/:instance_name/name
  def update_name
    Rails.logger.info "Evolution API update profile name called for instance: #{params[:instance_name]}"

    begin
      instance_name = params[:instance_name]
      name = params[:name]
      provider = params[:provider] || 'evolution'

      channel = find_whatsapp_channel_by_instance_name(instance_name, provider)

      if channel
        api_url = channel.provider_config['api_url']
        api_hash = channel.provider_config['admin_token']

        result = update_profile_name(api_url, api_hash, instance_name, name)

        render json: {
          success: true,
          data: result
        }
      else
        render json: { error: "Channel not found for instance: #{instance_name}" }, status: :not_found
      end
    rescue StandardError => e
      Rails.logger.error "Evolution API update profile name error: #{e.class} - #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/evolution/profile/:instance_name/status
  def update_status
    Rails.logger.info "Evolution API update profile status called for instance: #{params[:instance_name]}"

    begin
      instance_name = params[:instance_name]
      status = params[:status]
      provider = params[:provider] || 'evolution'

      channel = find_whatsapp_channel_by_instance_name(instance_name, provider)

      if channel
        api_url = channel.provider_config['api_url']
        api_hash = channel.provider_config['admin_token']

        result = update_profile_status(api_url, api_hash, instance_name, status)

        render json: {
          success: true,
          data: result
        }
      else
        render json: { error: "Channel not found for instance: #{instance_name}" }, status: :not_found
      end
    rescue StandardError => e
      Rails.logger.error "Evolution API update profile status error: #{e.class} - #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/evolution/profile/:instance_name/picture
  def update_picture
    Rails.logger.info "Evolution API update profile picture called for instance: #{params[:instance_name]}"

    begin
      instance_name = params[:instance_name]
      picture_url = params[:picture]
      provider = params[:provider] || 'evolution'

      channel = find_whatsapp_channel_by_instance_name(instance_name, provider)

      if channel
        api_url = channel.provider_config['api_url']
        api_hash = channel.provider_config['admin_token']

        result = update_profile_picture(api_url, api_hash, instance_name, picture_url)

        # Also update the inbox avatar
        update_inbox_avatar(channel.inbox, picture_url)

        render json: {
          success: true,
          data: result
        }
      else
        render json: { error: "Channel not found for instance: #{instance_name}" }, status: :not_found
      end
    rescue StandardError => e
      Rails.logger.error "Evolution API update profile picture error: #{e.class} - #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/evolution/profile/:instance_name/picture
  def remove_picture
    Rails.logger.info "Evolution API remove profile picture called for instance: #{params[:instance_name]}"

    begin
      instance_name = params[:instance_name]
      provider = params[:provider] || 'evolution'

      channel = find_whatsapp_channel_by_instance_name(instance_name, provider)

      if channel
        api_url = channel.provider_config['api_url']
        api_hash = channel.provider_config['admin_token']

        result = remove_profile_picture(api_url, api_hash, instance_name)

        # Remove inbox avatar
        channel.inbox.update(avatar: nil) if channel.inbox

        render json: {
          success: true,
          data: result
        }
      else
        render json: { error: "Channel not found for instance: #{instance_name}" }, status: :not_found
      end
    rescue StandardError => e
      Rails.logger.error "Evolution API remove profile picture error: #{e.class} - #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  private

  def find_whatsapp_channel_by_instance_name(instance_name, provider)
    Channel::Whatsapp.joins(:inbox)
                     .where(provider: provider)
                     .find do |ch|
      config = ch.provider_config || {}
      candidates = [
        config['instance_name'],
        config['instance_uuid'],
        config['instanceName'],
        config['instance'],
        ch.inbox&.name
      ].compact.uniq
      candidates.include?(instance_name)
    end
  end

  def fetch_profile(api_url, api_hash, instance_name, phone_number)
    profile_url = "#{api_url.chomp('/')}/chat/fetchProfile/#{instance_name}"
    Rails.logger.info "Evolution API: Fetching profile from #{profile_url}"

    uri = URI.parse(profile_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Post.new(uri)
    request['apikey'] = api_hash
    request['Content-Type'] = 'application/json'
    request.body = { number: phone_number }.to_json

    response = http.request(request)
    Rails.logger.info "Evolution API: Fetch profile response code: #{response.code}"
    Rails.logger.info "Evolution API: Fetch profile response body: #{response.body}"

    raise "Failed to fetch profile. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution API: Fetch profile JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution API fetch profile endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution API: Fetch profile connection error: #{e.class} - #{e.message}"
    raise "Failed to fetch profile: #{e.message}"
  end

  def update_profile_name(api_url, api_hash, instance_name, name)
    name_url = "#{api_url.chomp('/')}/chat/updateProfileName/#{instance_name}"
    Rails.logger.info "Evolution API: Updating profile name at #{name_url}"

    uri = URI.parse(name_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Post.new(uri)
    request['apikey'] = api_hash
    request['Content-Type'] = 'application/json'
    request.body = { name: name }.to_json

    response = http.request(request)
    Rails.logger.info "Evolution API: Update profile name response code: #{response.code}"
    Rails.logger.info "Evolution API: Update profile name response body: #{response.body}"

    raise "Failed to update profile name. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution API: Update profile name JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution API update profile name endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution API: Update profile name connection error: #{e.class} - #{e.message}"
    raise "Failed to update profile name: #{e.message}"
  end

  def update_profile_status(api_url, api_hash, instance_name, status)
    status_url = "#{api_url.chomp('/')}/chat/updateProfileStatus/#{instance_name}"
    Rails.logger.info "Evolution API: Updating profile status at #{status_url}"

    uri = URI.parse(status_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Post.new(uri)
    request['apikey'] = api_hash
    request['Content-Type'] = 'application/json'
    request.body = { status: status }.to_json

    response = http.request(request)
    Rails.logger.info "Evolution API: Update profile status response code: #{response.code}"
    Rails.logger.info "Evolution API: Update profile status response body: #{response.body}"

    raise "Failed to update profile status. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution API: Update profile status JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution API update profile status endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution API: Update profile status connection error: #{e.class} - #{e.message}"
    raise "Failed to update profile status: #{e.message}"
  end

  def update_profile_picture(api_url, api_hash, instance_name, picture_url)
    picture_url_endpoint = "#{api_url.chomp('/')}/chat/updateProfilePicture/#{instance_name}"
    Rails.logger.info "Evolution API: Updating profile picture at #{picture_url_endpoint}"

    uri = URI.parse(picture_url_endpoint)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Post.new(uri)
    request['apikey'] = api_hash
    request['Content-Type'] = 'application/json'
    request.body = { picture: picture_url }.to_json

    response = http.request(request)
    Rails.logger.info "Evolution API: Update profile picture response code: #{response.code}"
    Rails.logger.info "Evolution API: Update profile picture response body: #{response.body}"

    raise "Failed to update profile picture. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution API: Update profile picture JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution API update profile picture endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution API: Update profile picture connection error: #{e.class} - #{e.message}"
    raise "Failed to update profile picture: #{e.message}"
  end

  def remove_profile_picture(api_url, api_hash, instance_name)
    picture_url = "#{api_url.chomp('/')}/chat/removeProfilePicture/#{instance_name}"
    Rails.logger.info "Evolution API: Removing profile picture at #{picture_url}"

    uri = URI.parse(picture_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Delete.new(uri)
    request['apikey'] = api_hash
    request['Content-Type'] = 'application/json'

    response = http.request(request)
    Rails.logger.info "Evolution API: Remove profile picture response code: #{response.code}"
    Rails.logger.info "Evolution API: Remove profile picture response body: #{response.body}"

    raise "Failed to remove profile picture. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution API: Remove profile picture JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution API remove profile picture endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution API: Remove profile picture connection error: #{e.class} - #{e.message}"
    raise "Failed to remove profile picture: #{e.message}"
  end

  def update_inbox_avatar(inbox, picture_url)
    return unless inbox && picture_url.present?

    Rails.logger.info "Evolution API: Updating inbox #{inbox.id} avatar with URL: #{picture_url}"

    # Download the image and attach it to the inbox
    require 'open-uri'

    begin
      downloaded_image = URI.open(picture_url)
      filename = "profile_#{inbox.id}_#{Time.now.to_i}.jpg"

      inbox.avatar.attach(
        io: downloaded_image,
        filename: filename,
        content_type: 'image/jpeg'
      )

      Rails.logger.info "Evolution API: Successfully updated inbox #{inbox.id} avatar"
    rescue StandardError => e
      Rails.logger.error "Evolution API: Failed to update inbox avatar: #{e.message}"
      # Don't raise error, just log it - avatar update is not critical
    end
  end
end
