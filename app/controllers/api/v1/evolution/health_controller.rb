class Api::V1::Evolution::HealthController < Api::V1::BaseController
  TIMEOUT_SECONDS = 5

  def show
    api_url = params[:api_url].to_s

    if api_url.blank?
      render json: { error: 'api_url is required' }, status: :bad_request
      return
    end

    uri = URI.parse("#{api_url.chomp('/')}/")

    unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
      render json: { error: 'invalid api_url' }, status: :bad_request
      return
    end

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = TIMEOUT_SECONDS
    http.read_timeout = TIMEOUT_SECONDS

    request = Net::HTTP::Get.new(uri)
    request['Accept'] = 'application/json'

    response = http.request(request)

    unless response.is_a?(Net::HTTPSuccess)
      render json: { status: response.code.to_i, error: 'upstream not healthy' },
             status: :bad_gateway
      return
    end

    render json: JSON.parse(response.body)
  rescue JSON::ParserError
    render json: { error: 'invalid response from evolution api' }, status: :bad_gateway
  rescue URI::InvalidURIError
    render json: { error: 'invalid api_url' }, status: :bad_request
  rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, SocketError => e
    render json: { error: "evolution api unreachable: #{e.message}" }, status: :bad_gateway
  end
end
