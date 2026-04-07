# frozen_string_literal: true

module BotRuntime
  module Config
    module_function

    def enabled?
      url.present?
    end

    def url
      ENV.fetch('BOT_RUNTIME_URL', nil)
    end

    def secret
      ENV.fetch('BOT_RUNTIME_SECRET', '')
    end

    def postback_base_url
      ENV.fetch('BOT_RUNTIME_POSTBACK_BASE_URL', '')
    end

    def timeout
      ENV.fetch('BOT_RUNTIME_TIMEOUT', '10').to_i
    end
  end
end
