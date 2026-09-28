# frozen_string_literal: true

module Templates
  module CategoryImporters
    class LabelsImporter < Base
      CATEGORY = 'labels'
      MODEL = ::Label
      UNIQUE_FIELD = :title
      # Titles are stored downcased and take only letters, digits and [ _-].
      CASE_INSENSITIVE = true
      PLAIN_SUFFIX = true
    end
  end
end
