class Webhooks::Trigger
  SUPPORTED_ERROR_HANDLE_EVENTS = %w[message_created message_updated].freeze

  def initialize(url, payload, webhook_type)
    @url = url
    @payload = payload
    @webhook_type = webhook_type
  end

  def self.execute(url, payload, webhook_type)
    new(url, payload, webhook_type).execute
  end

  def execute
    perform_request
  rescue StandardError => e
    handle_error(e)
    # Keep the legacy "Exception: Invalid webhook URL" prefix so existing
    # Loki/Sentry/Grafana alerts grepping for it keep matching; structured
    # context follows.
    Rails.logger.warn(
      "Exception: Invalid webhook URL #{loggable_url} : #{e.message} " \
      "(type=#{@webhook_type} event=#{@payload[:event]} error=#{e.class})"
    )
    # Re-raise ONLY for macro webhooks so Sidekiq surfaces the failure in
    # queue/error tracking. Other webhook types (account, inbox, agent_bot,
    # api_inbox) keep their legacy swallow-and-warn behaviour — re-raising
    # them would trigger the default ActiveJob retry policy (25 attempts
    # over ~21 days) across every listener that dispatches webhooks.
    raise if @webhook_type == :macro_webhook
  end

  private

  def perform_request
    RestClient::Request.execute(
      method: :post,
      url: request_url,
      payload: @payload.to_json,
      headers: { content_type: :json, accept: :json },
      timeout: 5
    )
  end

  def request_url
    internal_base_url = ENV['INTERNAL_WEBHOOK_BASE_URL'].to_s.strip
    return @url if internal_base_url.blank?

    public_uri = URI.parse(@url.to_s)
    public_host = ENV.fetch('INTERNAL_WEBHOOK_PUBLIC_HOST', 'webhook.agenciavetorial.com')
    return @url unless public_uri.host == public_host

    internal_uri = URI.parse(internal_base_url)
    return @url unless internal_uri.is_a?(URI::HTTP) && internal_uri.host.present?

    base_path = internal_uri.path.to_s.delete_suffix('/')
    request_path = public_uri.path.to_s.start_with?('/') ? public_uri.path : "/#{public_uri.path}"
    internal_uri.path = "#{base_path}#{request_path}"
    internal_uri.query = public_uri.query
    internal_uri.fragment = nil
    internal_uri.to_s
  rescue URI::InvalidURIError
    @url
  end

  def handle_error(error)
    return unless should_handle_error?
    return unless message

    update_message_status(error)
  end

  def should_handle_error?
    api_inbox_webhook? && SUPPORTED_ERROR_HANDLE_EVENTS.include?(@payload[:event])
  end

  def api_inbox_webhook?
    @webhook_type == :api_inbox_webhook
  end

  # Strip query string before logging. Account webhooks frequently carry
  # auth tokens in the query (`?token=...`); leaking those into Loki/Sentry
  # is a real risk. Path + host is enough to identify the destination.
  def loggable_url
    uri = URI.parse(@url.to_s)
    return @url.to_s if uri.host.blank?

    [uri.scheme, '://', uri.host, uri.path].join
  rescue URI::InvalidURIError
    '<unparseable>'
  end

  def update_message_status(error)
    Messages::StatusUpdateService.new(message, 'failed', error.message).perform
  end

  def message
    return if message_id.blank?

    @message ||= Message.find_by(id: message_id)
  end

  def message_id
    @payload[:id]
  end
end
