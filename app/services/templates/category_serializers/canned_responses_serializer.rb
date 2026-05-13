# frozen_string_literal: true

module Templates
  module CategorySerializers
    class CannedResponsesSerializer < Base
      ALLOW_LIST = %w[short_code content].freeze
      SLUG_FIELD = :short_code
    end
  end
end
