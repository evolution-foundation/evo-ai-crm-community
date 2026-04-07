class Api::V1::Evolution::SettingsController < Api::V1::BaseController
  def show
    Rails.logger.info "Evolution API get settings called for instance: #{params[:id]}"

    begin
      instance_name = params[:id]
      channel = find_whatsapp_channel_by_instance_name(instance_name)

      if channel
        api_url = channel.provider_config['api_url']
        api_hash = channel.provider_config['admin_token']

        result = get_settings(api_url, api_hash, instance_name)

        render json: {
          success: true,
          data: result
        }
      else
        render json: { error: "Channel not found for instance: #{instance_name}" }, status: :not_found
      end
    rescue StandardError => e
      Rails.logger.error "Evolution API get settings error: #{e.class} - #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  def create
    Rails.logger.info "Evolution API settings configuration called with params: #{params.inspect}"

    begin
      # Extract parameters
      settings_params = params[:settings] || params
      api_url = settings_params[:api_url]
      api_hash = settings_params[:api_hash]
      instance_name = settings_params[:instance_name]
      instance_settings = settings_params[:instance_settings]

      Rails.logger.info "Evolution API: Setting instance settings for #{instance_name}"

      # Set instance settings
      result = set_settings(api_url, api_hash, instance_name, instance_settings)

      render json: {
        success: true,
        message: 'Instance settings applied successfully',
        result: result
      }
    rescue StandardError => e
      Rails.logger.error "Evolution API settings configuration error: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  def update
    Rails.logger.info "Evolution API update settings called for instance: #{params[:id]}"

    begin
      instance_name = params[:id]
      settings = params[:settings]
      channel = find_whatsapp_channel_by_instance_name(instance_name)

      if channel
        api_url = channel.provider_config['api_url']
        api_hash = channel.provider_config['admin_token']

        result = set_settings(api_url, api_hash, instance_name, settings)

        render json: {
          success: true,
          message: 'Instance settings updated successfully',
          result: result
        }
      else
        render json: { error: "Channel not found for instance: #{instance_name}" }, status: :not_found
      end
    rescue StandardError => e
      Rails.logger.error "Evolution API update settings error: #{e.class} - #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  private

  def find_whatsapp_channel_by_instance_name(instance_name)
    Channel::Whatsapp.joins(:inbox)
                     .where(provider: 'evolution')
                     .find do |ch|
      config = ch.provider_config || {}
      candidates = [
        config['instance_name'],
        config['instanceName'],
        config['instance'],
        ch.inbox&.name
      ].compact.uniq
      candidates.include?(instance_name)
    end
  end

  def get_settings(api_url, api_hash, instance_name)
    settings_url = "#{api_url.chomp('/')}/settings/find/#{instance_name}"
    Rails.logger.info "Evolution API: Getting instance settings from #{settings_url}"

    uri = URI.parse(settings_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Get.new(uri)
    request['apikey'] = api_hash

    response = http.request(request)
    Rails.logger.info "Evolution API: Get settings response code: #{response.code}"
    Rails.logger.info "Evolution API: Get settings response body: #{response.body}"

    raise "Failed to get instance settings. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution API: Get settings JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution API get settings endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution API: Get settings connection error: #{e.class} - #{e.message}"
    raise "Failed to get instance settings: #{e.message}"
  end

  def set_settings(api_url, api_hash, instance_name, instance_settings)
    settings_url = "#{api_url.chomp('/')}/settings/set/#{instance_name}"
    Rails.logger.info "Evolution API: Setting instance settings at #{settings_url}"

    # Prepare settings body
    settings_body = {
      rejectCall: instance_settings['rejectCall'],
      msgCall: instance_settings['msgCall'],
      groupsIgnore: instance_settings['groupsIgnore'],
      alwaysOnline: instance_settings['alwaysOnline'],
      readMessages: instance_settings['readMessages'],
      syncFullHistory: instance_settings['syncFullHistory'],
      readStatus: instance_settings['readStatus']
    }

    uri = URI.parse(settings_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Post.new(uri)
    request['apikey'] = api_hash
    request['Content-Type'] = 'application/json'
    request.body = settings_body.to_json

    Rails.logger.info "Evolution API: Settings request headers: #{request.to_hash}"
    Rails.logger.info "Evolution API: Settings request body: #{request.body}"

    response = http.request(request)
    Rails.logger.info "Evolution API: Settings response code: #{response.code}"
    Rails.logger.info "Evolution API: Settings response body: #{response.body}"

    raise "Failed to set instance settings. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution API: Settings JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution API settings endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution API: Settings connection error: #{e.class} - #{e.message}"
    raise "Failed to set instance settings: #{e.message}"
  end
end
