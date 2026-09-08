# frozen_string_literal: true

require 'delegate'

# ActionCable logs the raw subscription identifier on several framework paths it
# owns (unsubscribe, command failures, messages after close). Since CRM-537 that
# identifier carries the auth access_token, and for widget visitors the
# contact_inbox pubsub_token is still the credential, so the cable logger redacts
# both before the line reaches the log. Covers the JSON shape, the JSON escaped any
# number of times (`inspect` of a frame that itself embeds the identifier), Ruby
# hash inspect and query strings.
module ActionCableLogRedaction
  REDACTED = '[REDACTED]'
  KEYS = /(?:access_token|pubsub_token)/
  PATTERNS = [
    /(\\*["']#{KEYS}\\*["']\s*(?:=>|:)\s*\\*["'])([^"'\\]+)/,
    /(\b#{KEYS}=)([^&\s"']+)/
  ].freeze

  def self.redact(message)
    return message unless message.is_a?(String) && message.match?(KEYS)

    PATTERNS.reduce(message) { |text, pattern| text.gsub(pattern) { "#{Regexp.last_match(1)}#{REDACTED}" } }
  end

  class Logger < SimpleDelegator
    %i[debug info warn error fatal unknown].each do |severity|
      define_method(severity) do |message = nil, &block|
        __getobj__.public_send(severity, ActionCableLogRedaction.redact(message || block&.call))
      end
    end

    # Logger#add falls back to progname as the message when message is nil.
    def add(severity, message = nil, progname = nil, &block)
      __getobj__.add(severity, ActionCableLogRedaction.redact(message || block&.call), ActionCableLogRedaction.redact(progname))
    end
  end

  def self.install!(config)
    return if config.logger.is_a?(Logger)

    config.logger = Logger.new(config.logger)
  end
end
