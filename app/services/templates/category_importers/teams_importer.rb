# frozen_string_literal: true

module Templates
  module CategoryImporters
    class TeamsImporter < Base
      CATEGORY = 'teams'
      MODEL = ::Team
      UNIQUE_FIELD = :name
      CASE_INSENSITIVE = true
    end
  end
end
