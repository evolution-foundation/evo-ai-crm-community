class Api::V1::Evolution::InstancesController < Api::V1::BaseController
  def index
    Rails.logger.info "Evolution API fetch instances called with params: #{params.inspect}"

    begin
      instance_name = params[:instanceName]

      if instance_name.present?
        # Fetch specific instance
        channel = find_whatsapp_channel_by_instance_name(instance_name)

        if channel
          api_url = channel.provider_config['api_url']
          api_hash = channel.provider_config['admin_token']

          result = get_instance_info(api_url, api_hash, instance_name)

          render json: {
            success: true,
            data: result
          }
        else
          render json: { error: "Channel not found for instance: #{instance_name}" }, status: :not_found
        end
      else
        # List all instances for this account
        channels = Channel::Whatsapp.joins(:inbox)
                                    .where(provider: 'evolution')
                                    

        instances = channels.map do |ch|
          {
            instance_name: ch.provider_config['instance_name'],
            phone_number: ch.phone_number,
            api_url: ch.provider_config['api_url'],
            status: 'connected' # You might want to check actual status
          }
        end

        render json: {
          success: true,
          data: instances
        }
      end
    rescue StandardError => e
      Rails.logger.error "Evolution API fetch instances error: #{e.class} - #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  def logout
    Rails.logger.info "Evolution API logout called for instance: #{params[:id]}"

    begin
      instance_name = params[:id]
      channel = find_whatsapp_channel_by_instance_name(instance_name)

      if channel
        api_url = channel.provider_config['api_url']
        api_hash = channel.provider_config['admin_token']

        result = logout_instance(api_url, api_hash, instance_name)

        render json: {
          success: true,
          message: 'Instance logged out successfully',
          result: result
        }
      else
        render json: { error: "Channel not found for instance: #{instance_name}" }, status: :not_found
      end
    rescue StandardError => e
      Rails.logger.error "Evolution API logout error: #{e.class} - #{e.message}"
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

  def get_instance_info(api_url, api_hash, instance_name)
    info_url = "#{api_url.chomp('/')}/instance/connectionState/#{instance_name}"
    Rails.logger.info "Evolution API: Getting instance info from #{info_url}"

    uri = URI.parse(info_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Get.new(uri)
    request['apikey'] = api_hash

    response = http.request(request)
    Rails.logger.info "Evolution API: Get instance info response code: #{response.code}"
    Rails.logger.info "Evolution API: Get instance info response body: #{response.body}"

    if response.is_a?(Net::HTTPSuccess)
      JSON.parse(response.body)
    else
      # If specific endpoint fails, return basic info
      {
        instance: {
          instanceName: instance_name,
          status: 'unknown'
        }
      }
    end
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution API: Get instance info JSON parse error: #{e.message}, Body: #{response&.body}"
    # Return basic info on parse error
    {
      instance: {
        instanceName: instance_name,
        status: 'unknown'
      }
    }
  rescue StandardError => e
    Rails.logger.error "Evolution API: Get instance info connection error: #{e.class} - #{e.message}"
    # Return basic info on connection error
    {
      instance: {
        instanceName: instance_name,
        status: 'unknown'
      }
    }
  end

  def logout_instance(api_url, api_hash, instance_name)
    logout_url = "#{api_url.chomp('/')}/instance/logout/#{instance_name}"
    Rails.logger.info "Evolution API: Logging out instance at #{logout_url}"

    uri = URI.parse(logout_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Delete.new(uri)
    request['apikey'] = api_hash
    request['Content-Type'] = 'application/json'

    response = http.request(request)
    Rails.logger.info "Evolution API: Logout response code: #{response.code}"
    Rails.logger.info "Evolution API: Logout response body: #{response.body}"

    raise "Failed to logout instance. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution API: Logout JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution API logout endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution API: Logout connection error: #{e.class} - #{e.message}"
    raise "Failed to logout instance: #{e.message}"
  end
end
