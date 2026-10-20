require 'net/http'

class Webhooks::WhatsappMirrorJob < ApplicationJob
  queue_as :low
  self.log_arguments = false
  retry_on StandardError, wait: :polynomially_longer, attempts: 12

  FIELDS = %w[messages smb_message_echoes standby].freeze
  WABA = '2257485551347138'.freeze
  PHONES = %w[1326344810560043 901155999742500 793999060456095].freeze

  def self.enqueue_allowed(params)
    return unless ENV['WHATSAPP_MIRROR_ENABLED'] == 'true'

    entries = Array(params[:entry]).filter_map do |entry|
      next unless entry[:id].to_s == WABA

      changes = Array(entry[:changes]).select do |change|
        allowed_change?(change)
      end
      entry.merge(changes: changes) if changes.any?
    end
    perform_later({ object: 'whatsapp_business_account', entry: entries }, Time.current.to_i) if entries.any?
  end

  def self.allowed_change?(change)
    FIELDS.include?(change[:field]) && PHONES.include?(change.dig(:value, :metadata, :phone_number_id).to_s)
  end

  def perform(payload, accepted_at)
    return unless ENV['WHATSAPP_MIRROR_ENABLED'] == 'true'
    raise 'Mirror retention expired; inspect dead jobs' if Time.current.to_i - accepted_at > 24.hours.to_i

    deliver(payload)
  end

  private

  def deliver(payload)
    uri = URI(ENV.fetch('WHATSAPP_MIRROR_URL'))
    raise 'Mirror requires HTTPS' unless uri.scheme == 'https'

    token = ENV.fetch('WHATSAPP_MIRROR_TOKEN')
    raise 'Mirror token too short' if token.bytesize < 32

    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['Authorization'] = "Bearer #{token}"
    request.body = payload.to_json
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 20) { |http| http.request(request) }
    raise "Mirror rejected HTTP #{response.code}" unless response.code == '200' && JSON.parse(response.body)['status'] == 'persisted'
  end
end
