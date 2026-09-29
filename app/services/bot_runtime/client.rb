# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

module BotRuntime
  class Client
    CIRCUIT_BREAKER = CircuitBreaker.new(max_failures: 5, reset_timeout: 30)

    def send_event(event)
      CIRCUIT_BREAKER.call do
        perform_request('/events', event)
      end
    end

    # Presence is a best-effort, fire-and-forget signal — deliberately NOT
    # routed through CIRCUIT_BREAKER, which guards real message delivery. A
    # burst of presence failures (e.g. a provider sending malformed payloads)
    # must never open the breaker and block actual AI replies.
    def send_presence_event(event)
      perform_request('/events/presence', event)
    end

    private

    def perform_request(path, event)
      uri = URI.parse("#{BotRuntime::Config.url}#{path}")

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = BotRuntime::Config.timeout
      http.read_timeout = BotRuntime::Config.timeout

      request = Net::HTTP::Post.new(uri.path)
      request['Content-Type'] = 'application/json'
      request['X-Bot-Runtime-Secret'] = BotRuntime::Config.secret
      request.body = event.to_json

      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        raise RequestError, "Bot Runtime responded with #{response.code}: #{response.body}"
      end

      response
    end

    class RequestError < StandardError; end
  end
end
