# frozen_string_literal: true

class EvoAiCoreService
  include HTTParty

  # Use Core AI Service directly
  base_uri ENV.fetch('EVO_AI_CORE_SERVICE_URL', 'http://localhost:5555')

  # Failures talking to evo-core surface as these two, never as a bare
  # StandardError (which Api::BaseController turns into a 500).

  # evo-core answered with a non-2xx; `status` is the code it returned.
  class UpstreamError < StandardError
    attr_reader :status

    def initialize(message = 'evo-core returned an error', status: nil)
      @status = status
      super(message)
    end
  end

  # evo-core was never reached (refused, DNS/TLS, timeout, unusable base_uri).
  class UnavailableError < StandardError
    def initialize(message = 'AI core service is unavailable')
      super
    end
  end

  # Listed one by one so an unrelated SystemCallError is not reported as
  # "core down". Net::OpenTimeout/ReadTimeout are Timeout::Error.
  NETWORK_ERRORS = [
    Errno::ECONNREFUSED,
    Errno::ECONNRESET,
    Errno::ETIMEDOUT,
    Errno::EHOSTUNREACH,
    Errno::ENETUNREACH,
    Errno::EPIPE,
    EOFError,
    SocketError,
    Timeout::Error,
    OpenSSL::SSL::SSLError,
    URI::Error,
    Net::ProtocolError,
    Net::HTTPBadResponse,
    Net::HTTPHeaderSyntaxError,
    HTTParty::Error
  ].freeze

  class << self
    def build_headers(request_headers = nil)
      # Get current user from thread context or MCP thread storage
      current_user = Current.user || Thread.current[:mcp_authenticated_user]


      headers = {
        'Content-Type' => 'application/json',
        'Accept' => 'application/json'
      }

      # Pass the current user's authentication token to Core AI Service
      if current_user
        if request_headers
          # Handle different types of headers (Rails request headers or simple hash from MCP tools)
          if request_headers.respond_to?(:env)
            # Rails request headers (ActionDispatch::Http::Headers)
            headers_hash = request_headers.env

            # Pass through OAuth headers
            ['Authorization', 'X-User-Id'].each do |header|
              value = headers_hash[header] || headers_hash[header.upcase] || headers_hash["HTTP_#{header.upcase.gsub('-', '_')}"]
              headers[header] = value if value.present?
            end

            # Also try Authorization header
            auth_header = headers_hash['Authorization'] || headers_hash['HTTP_AUTHORIZATION']
            headers['Authorization'] = auth_header if auth_header.present?

            # Try api_access_token headers for access token auth
            api_token = headers_hash['api_access_token'] || headers_hash['HTTP_API_ACCESS_TOKEN']
            headers['api_access_token'] = api_token if api_token.present?
          else
            # Simple hash from MCP tools - use directly
            request_headers.each do |key, value|
              headers[key] = value if value.present?
            end
          end
        end

        # Add X-User-Id if not already present from MCP headers
        headers['X-User-Id'] ||= current_user.id.to_s
      end

      headers.compact
    end

    # Legacy method for backward compatibility - renamed to avoid HTTParty conflicts
    def legacy_headers(request_headers = nil)
      build_headers(request_headers)
    end

    # HTTParty might be calling this automatically - redirect to build_headers
    def headers
      build_headers
    end

    # Not named `perform_request`: HTTParty already defines a private one that
    # every verb funnels through, and overriding it breaks all requests.
    def call_core(http_method, url, options = {})
      response = public_send(http_method, url, options)
      handle_response(response)
    rescue *NETWORK_ERRORS => e
      Rails.logger.error(
        "EvoAiCoreService: #{http_method.to_s.upcase} #{base_uri}#{url} did not reach evo-core — " \
        "#{e.class}: #{e.message}"
      )
      raise UnavailableError
    end

    def handle_response(response)
      parsed = parse_body(response)

      case response.code
      when 200, 201
        # Unwrap the `{ data: ... }` envelope; a bare array or a non-JSON body
        # is only a Hash-less `parsed`, not an error.
        parsed.is_a?(Hash) ? (parsed['data'] || parsed) : parsed
      when 204
        nil
      else
        raise UpstreamError.new(upstream_message(parsed, response.code), status: response.code)
      end
    end

    # HTTParty parses lazily and raises on an invalid body under a JSON
    # content-type, on any status.
    def parse_body(response)
      response.parsed_response
    rescue JSON::ParserError => e
      Rails.logger.error("EvoAiCoreService: evo-core responded #{response.code} with an unparsable body — #{e.message[0, 200]}")
      raise UpstreamError.new("evo-core responded #{response.code} with an unparsable body", status: response.code)
    end

    # Logged by the caller; controllers decide what reaches the client.
    def upstream_message(parsed, code)
      message = parsed.is_a?(Hash) ? (parsed['error'] || parsed['message']) : nil
      message.presence || "evo-core responded #{code}"
    end

    # Agents endpoints (Core AI Service)
    def list_agents(params = {}, request_headers = nil)
      url = "/api/v1/agents"
      Rails.logger.info "EvoAiCoreService.list_agents - Params: #{params}"

      call_core(:get, url, {
        query: params,
        headers: build_headers(request_headers)
      })
    end

    def get_agent(agent_id, request_headers = nil)
      url = "/api/v1/agents/#{agent_id}"
      call_core(:get, url, {
        headers: build_headers(request_headers)
      })
    end

    def create_agent(agent_data, request_headers = nil)
      url = "/api/v1/agents"
      call_core(:post, url, {
        body: agent_data.to_json,
        headers: build_headers(request_headers)
      })
    end

    def update_agent(agent_id, agent_data, request_headers = nil)
      url = "/api/v1/agents/#{agent_id}"
      call_core(:put, url, {
        body: agent_data.to_json,
        headers: build_headers(request_headers)
      })
    end

    def delete_agent(agent_id, request_headers = nil)
      url = "/api/v1/agents/#{agent_id}"
      call_core(:delete, url, {
        headers: build_headers(request_headers)
      })
    end

    def sync_evolution_bot(agent_id, request_headers = nil)
      url = "/api/v1/agents/#{agent_id}/sync_evolution"
      call_core(:post, url, {
        body: {}.to_json,
        headers: build_headers(request_headers)
      })
    end

    def assign_folder(agent_id, folder_id)
      url = "/api/v1/ai_agents/#{agent_id}/assign_folder"
      response = put(url, {
        body: { folder_id: folder_id }.to_json,
        headers: legacy_headers
      })
      handle_response(response)
    end

    def get_share_agent(agent_id)
      url = "/api/v1/ai_agents/#{agent_id}/share"
      response = get(url, {
        headers: legacy_headers
      })
      handle_response(response)
    end

    def get_shared_agent(agent_id)
      url = "/api/v1/ai_agents/#{agent_id}/shared"
      response = get(url, {
        headers: legacy_headers
      })
      handle_response(response)
    end

    # Folders endpoints (using Core AI Service)
    def list_folders(params = {}, request_headers = nil)
      url = "/api/v1/folders"
      response = get(url, {
        query: params,
        headers: build_headers(request_headers)
      })
      handle_response(response)
    end

    def get_folder(folder_id, request_headers = nil)
      url = "/api/v1/folders/#{folder_id}"
      response = get(url, {
        headers: build_headers(request_headers)
      })
      handle_response(response)
    end

    def create_folder(folder_data, request_headers = nil)
      url = "/api/v1/folders"
      response = post(url, {
        body: folder_data.to_json,
        headers: build_headers(request_headers)
      })
      handle_response(response)
    end

    def update_folder(folder_id, folder_data, request_headers = nil)
      url = "/api/v1/folders/#{folder_id}"
      response = put(url, {
        body: folder_data.to_json,
        headers: build_headers(request_headers)
      })
      handle_response(response)
    end

    def delete_folder(folder_id, request_headers = nil)
      url = "/api/v1/folders/#{folder_id}"
      response = delete(url, {
        headers: build_headers(request_headers)
      })
      handle_response(response)
    end

    # API Keys endpoints (using Core AI Service)
    def list_api_keys(params = {}, request_headers = nil)
      url = "/api/v1/agents/apikeys"
      response = get(url, {
        query: params,
        headers: build_headers(request_headers)
      })
      handle_response(response)
    end

    def get_api_key(key_id, request_headers = nil)
      url = "/api/v1/agents/apikeys/#{key_id}"
      response = get(url, {
        headers: build_headers(request_headers)
      })
      handle_response(response)
    end

    def create_api_key(api_key_data, request_headers = nil)
      url = "/api/v1/agents/apikeys"
      response = post(url, {
        body: api_key_data.to_json,
        headers: build_headers(request_headers)
      })
      handle_response(response)
    end

    def update_api_key(key_id, api_key_data, request_headers = nil)
      url = "/api/v1/agents/apikeys/#{key_id}"
      response = put(url, {
        body: api_key_data.to_json,
        headers: build_headers(request_headers)
      })
      handle_response(response)
    end

    def delete_api_key(key_id, request_headers = nil)
      url = "/api/v1/agents/apikeys/#{key_id}"
      response = delete(url, {
        headers: build_headers(request_headers)
      })
      handle_response(response)
    end

    # MCP Servers endpoints (using Core AI Service)
    def list_mcp_servers(params = {}, request_headers = nil)
      url = "/api/v1/mcp-servers"
      response = get(url, {
        query: params,
        headers: build_headers(request_headers)
      })
      handle_response(response)
    end

    def get_mcp_server(server_id, request_headers = nil)
      url = "/api/v1/mcp-servers/#{server_id}"
      response = get(url, {
        headers: build_headers(request_headers)
      })
      handle_response(response)
    end

    def create_mcp_server(server_data, request_headers = nil)
      url = "/api/v1/mcp-servers"
      response = post(url, {
        body: server_data.to_json,
        headers: build_headers(request_headers)
      })
      handle_response(response)
    end

    def update_mcp_server(server_id, server_data, request_headers = nil)
      url = "/api/v1/mcp-servers/#{server_id}"
      response = put(url, {
        body: server_data.to_json,
        headers: build_headers(request_headers)
      })
      handle_response(response)
    end

    def delete_mcp_server(server_id, request_headers = nil)
      url = "/api/v1/mcp-servers/#{server_id}"
      response = delete(url, {
        headers: build_headers(request_headers)
      })
      handle_response(response)
    end

    # Custom Tools endpoints (using Core AI Service)
    def list_custom_tools(params = {}, request_headers = nil)
      url = "/api/v1/custom-tools"
      response = get(url, {
        query: params,
        headers: build_headers(request_headers)
      })
      handle_response(response)
    end

    def get_custom_tool(tool_id, request_headers = nil)
      url = "/api/v1/custom-tools/#{tool_id}"
      response = get(url, {
        headers: build_headers(request_headers)
      })
      handle_response(response)
    end

    def create_custom_tool(tool_data, request_headers = nil)
      url = "/api/v1/custom-tools"
      response = post(url, {
        body: tool_data.to_json,
        headers: build_headers(request_headers)
      })
      handle_response(response)
    end

    def update_custom_tool(tool_id, tool_data, request_headers = nil)
      url = "/api/v1/custom-tools/#{tool_id}"
      response = put(url, {
        body: tool_data.to_json,
        headers: build_headers(request_headers)
      })
      handle_response(response)
    end

    def delete_custom_tool(tool_id, request_headers = nil)
      url = "/api/v1/custom-tools/#{tool_id}"
      response = delete(url, {
        headers: build_headers(request_headers)
      })
      handle_response(response)
    end

    def test_custom_tool(tool_id, request_headers = nil)
      url = "/api/v1/custom-tools/#{tool_id}/test"
      response = get(url, {
        headers: build_headers(request_headers)
      })
      handle_response(response)
    end

    # Custom MCP Servers endpoints (using Core AI Service)
    def list_custom_mcp_servers(params = {}, request_headers = nil)
      url = "/api/v1/custom-mcp-servers"
      response = get(url, {
        query: params,
        headers: build_headers(request_headers)
      })
      handle_response(response)
    end

    def get_custom_mcp_server(server_id, request_headers = nil)
      url = "/api/v1/custom-mcp-servers/#{server_id}"
      response = get(url, {
        headers: build_headers(request_headers)
      })
      handle_response(response)
    end

    def create_custom_mcp_server(server_data, request_headers = nil)
      url = "/api/v1/custom-mcp-servers"
      response = post(url, {
        body: server_data.to_json,
        headers: build_headers(request_headers)
      })
      handle_response(response)
    end

    def update_custom_mcp_server(server_id, server_data, request_headers = nil)
      url = "/api/v1/custom-mcp-servers/#{server_id}"
      response = put(url, {
        body: server_data.to_json,
        headers: build_headers(request_headers)
      })
      handle_response(response)
    end

    def delete_custom_mcp_server(server_id, request_headers = nil)
      url = "/api/v1/custom-mcp-servers/#{server_id}"
      response = delete(url, {
        headers: build_headers(request_headers)
      })
      handle_response(response)
    end

    def test_custom_mcp_server(server_id, request_headers = nil)
      url = "/api/v1/custom-mcp-servers/#{server_id}/test"
      response = get(url, {
        headers: build_headers(request_headers)
      })
      handle_response(response)
    end
  end
end
