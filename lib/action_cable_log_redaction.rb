# frozen_string_literal: true

require 'delegate'

# ActionCable logs the raw subscription identifier on several framework paths it
# owns (unsubscribe, command failures, messages after close). Since CRM-537 that
# identifier carries the auth access_token, so the cable logger redacts it before
# the line reaches the log. Covers the JSON shape, the escaped JSON inside
# `inspect`, Ruby hash inspect and query strings.
module ActionCableLogRedaction
  REDACTED = '[REDACTED]'
  PATTERNS = [
    /(\\?["']access_token\\?["']\s*(?:=>|:)\s*\\?["'])([^"'\\]+)/,
    /(\baccess_token=)([^&\s"']+)/
  ].freeze

  def self.redact(message)
    return message unless message.is_a?(String) && message.include?('access_token')

    PATTERNS.reduce(message) { |text, pattern| text.gsub(pattern) { "#{Regexp.last_match(1)}#{REDACTED}" } }
  end

  class Logger < SimpleDelegator
    %i[debug info warn error fatal unknown].each do |severity|
      define_method(severity) do |message = nil, &block|
        __getobj__.public_send(severity, ActionCableLogRedaction.redact(message || block&.call))
      end
    end

    def add(severity, message = nil, progname = nil, &block)
      __getobj__.add(severity, ActionCableLogRedaction.redact(message || block&.call), progname)
    end
  end

  def self.install!(config)
    return if config.logger.is_a?(Logger)

    config.logger = Logger.new(config.logger)
  end
end
