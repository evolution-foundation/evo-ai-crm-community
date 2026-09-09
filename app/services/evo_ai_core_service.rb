# frozen_string_literal: true

class EvoAiCoreService
  include HTTParty

  # Use Core AI Service directly
  base_uri ENV.fetch('EVO_AI_CORE_SERVICE_URL', 'http://localhost:5555')

  # CRM-565 — this class is the CRM half of a proxy, and raising a bare StandardError
  # from it makes the CRM look broken for a failure that happened somewhere else:
  # Api::BaseController's `rescue_from StandardError` turns every one of them into a
  # 500. These two errors are the honest outcomes of a failed call to evo-core, and
  # they carry enough for a controller to answer with a status the client can act on.

  # evo-core answered, but with a non-2xx. `status` is the code IT returned.
  class UpstreamError < StandardError
    attr_reader :status

    def initialize(message = 'evo-core returned an error', status: nil)
      @status = status
      super(message)
    end
  end

  # evo-core was never reached: connection refused, DNS/TLS failure, timeout, or a
  # base_uri that is not a usable URL (with EVO_AI_CORE_SERVICE_URL unset the default
  # `http://localhost:5555` refuses inside the CRM container).
  class UnavailableError < StandardError
    def initialize(message = 'AI core service is unavailable')
      super
    end
  end

  # Everything here means "the request never got an answer", so it maps to
  # UnavailableError. Net::OpenTimeout/Net::ReadTimeout are Timeout::Error;
  # Errno::ECONNREFUSED & friends are listed one by one so an unrelated
  # SystemCallError is not silently reported as an availability problem.
  NETWORK_ERRORS = [
    Errno::ECONNREFUSED,
    Errno::ECONNRESET,
    Errno::EHOSTUNREACH,
    Errno::ENETUNREACH,
    Errno::EPIPE,
    EOFError,
    SocketError,
    Timeout::Error,
    OpenSSL::SSL::SSLError,
    URI::Error,
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

    # Runs one call against evo-core and hands back the parsed payload. Network and
    # configuration failures never surface as themselves: they become
    # UnavailableError, so a caller cannot mistake "the core is down" for "the CRM
    # is broken". The detail stays in the log, where it is useful, instead of in a
    # response body a customer reads.
    #
    # Named `call_core`, not `perform_request`: HTTParty::ClassMethods already has a
    # private `perform_request`, and every verb (get/post/put/delete) funnels through
    # it. Defining one here overrode it, so each verb called THIS method with
    # HTTParty's own arguments and every request broke, working ones included.
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
      # Return the complete response from evo-ai-core-service
      # The service already returns standardized format: { success, data, message, meta }
      parsed = response.parsed_response

      case response.code
      when 200, 201
        # Extract payload if it exists (Evolution API format). The guard is not
        # cosmetic: `parsed` is only a Hash when the core answered with a JSON
        # object. A bare JSON array (`[...]`) made `dig('data')` raise TypeError and
        # a non-JSON body (an HTML error page from a gateway, say) made it raise
        # NoMethodError — both landing on the CRM as a 500 for a 200 upstream.
        parsed.is_a?(Hash) ? (parsed['data'] || parsed) : parsed
      when 204
        nil
      else
        raise UpstreamError.new(upstream_message(response), status: response.code)
      end
    end

    # The core's own wording when it sent a JSON object with an `error`/`message`
    # key, else a neutral line. Controllers decide whether any of it reaches the
    # client; this is what gets logged either way.
    def upstream_message(response)
      parsed = response.parsed_response
      message = parsed.is_a?(Hash) ? (parsed['error'] || parsed['message']) : nil
      message.presence || "evo-core responded #{response.code}"
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
