class Api::V1::Evolution::ProxiesController < Api::V1::BaseController
  def show
    Rails.logger.info "Evolution API get proxy called for instance: #{params[:id]}"

    begin
      instance_name = params[:id]
      channel = find_whatsapp_channel_by_instance_name(instance_name)

      if channel
        api_url = channel.provider_config['api_url']
        api_hash = channel.provider_config['admin_token']

        result = get_proxy(api_url, api_hash, instance_name)

        render json: {
          success: true,
          data: result
        }
      else
        render json: { error: "Channel not found for instance: #{instance_name}" }, status: :not_found
      end
    rescue StandardError => e
      Rails.logger.error "Evolution API get proxy error: #{e.class} - #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  def create
    Rails.logger.info "Evolution API proxy configuration called with params: #{params.inspect}"

    begin
      # Extract parameters
      proxy_params = params[:proxy] || params
      api_url = proxy_params[:api_url]
      api_hash = proxy_params[:api_hash]
      instance_name = proxy_params[:instance_name]
      proxy_settings = proxy_params[:proxy_settings]

      Rails.logger.info "Evolution API: Setting proxy for instance #{instance_name}"

      # Set proxy configuration
      result = set_proxy(api_url, api_hash, instance_name, proxy_settings)

      render json: {
        success: true,
        message: 'Proxy settings applied successfully',
        result: result
      }
    rescue StandardError => e
      Rails.logger.error "Evolution API proxy configuration error: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
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

  def get_proxy(api_url, api_hash, instance_name)
    proxy_url = "#{api_url.chomp('/')}/settings/find/#{instance_name}"
    Rails.logger.info "Evolution API: Getting proxy settings from #{proxy_url}"

    uri = URI.parse(proxy_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Get.new(uri)
    request['apikey'] = api_hash

    response = http.request(request)
    Rails.logger.info "Evolution API: Get proxy response code: #{response.code}"
    Rails.logger.info "Evolution API: Get proxy response body: #{response.body}"

    raise "Failed to get proxy settings. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    # Extract proxy-related settings from the response
    data = JSON.parse(response.body)
    proxy_data = data['proxy'] || {}

    {
      enabled: proxy_data['enabled'] || false,
      host: proxy_data['host'],
      port: proxy_data['port'],
      protocol: proxy_data['protocol'],
      username: proxy_data['username']
    }
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution API: Get proxy JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution API get proxy endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution API: Get proxy connection error: #{e.class} - #{e.message}"
    raise "Failed to get proxy settings: #{e.message}"
  end

  def set_proxy(api_url, api_hash, instance_name, proxy_settings)
    proxy_url = "#{api_url.chomp('/')}/settings/set/#{instance_name}"
    Rails.logger.info "Evolution API: Setting proxy at #{proxy_url}"

    # Prepare proxy body
    proxy_body = {
      proxy: {
        enabled: proxy_settings['enabled'],
        host: proxy_settings['host'],
        port: proxy_settings['port'],
        protocol: proxy_settings['protocol'],
        username: proxy_settings['username'],
        password: proxy_settings['password']
      }
    }

    uri = URI.parse(proxy_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Post.new(uri)
    request['apikey'] = api_hash
    request['Content-Type'] = 'application/json'
    request.body = proxy_body.to_json

    Rails.logger.info "Evolution API: Proxy request headers: #{request.to_hash}"
    Rails.logger.info "Evolution API: Proxy request body: #{request.body}"

    response = http.request(request)
    Rails.logger.info "Evolution API: Proxy response code: #{response.code}"
    Rails.logger.info "Evolution API: Proxy response body: #{response.body}"

    raise "Failed to set proxy. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution API: Proxy JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution API proxy endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution API: Proxy connection error: #{e.class} - #{e.message}"
    raise "Failed to set proxy: #{e.message}"
  end
end
