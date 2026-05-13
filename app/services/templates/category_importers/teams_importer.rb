# frozen_string_literal: true

module Templates
  module CategoryImporters
    class TeamsImporter < Base
      CATEGORY = 'teams'
      MODEL = ::Team
      UNIQUE_FIELD = :name
    end
  end
end
