# frozen_string_literal: true

module Templates
  module CategoryImporters
    class CannedResponsesImporter < Base
      CATEGORY = 'canned_responses'
      MODEL = ::CannedResponse
      UNIQUE_FIELD = :short_code
    end
  end
end
