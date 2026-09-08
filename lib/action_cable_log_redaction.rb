# frozen_string_literal: true

require 'delegate'

# ActionCable logs the raw subscription identifier on framework paths the channel does
# not own (unsubscribe, command failures, messages after close), and since CRM-537 that
# identifier carries the agent access_token — the widget contact's pubsub_token too.
# Redacts both in the JSON, escaped-JSON (any depth), hash-inspect and query forms.
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
    # The block is FORWARDED, never resolved here: Logger skips it below the level, and
    # ActionCable builds one per broadcast (`Broadcasting#broadcast` inspects the payload).
    %i[debug info warn error fatal unknown].each do |severity|
      define_method(severity) do |message = nil, &block|
        next __getobj__.public_send(severity) { ActionCableLogRedaction.redact(block.call) } if block

        __getobj__.public_send(severity, ActionCableLogRedaction.redact(message))
      end
    end

    # Logger#add falls back to progname as the message when message and block are nil.
    def add(severity, message = nil, progname = nil)
      if block_given? && message.nil?
        return __getobj__.add(severity, nil, ActionCableLogRedaction.redact(progname)) { ActionCableLogRedaction.redact(yield) }
      end

      __getobj__.add(severity, ActionCableLogRedaction.redact(message), ActionCableLogRedaction.redact(progname))
    end
  end

  def self.install!(config)
    return if config.logger.is_a?(Logger)

    config.logger = Logger.new(config.logger)
  end
end
