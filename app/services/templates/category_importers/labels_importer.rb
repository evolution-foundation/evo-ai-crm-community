# frozen_string_literal: true

module Templates
  module CategoryImporters
    class LabelsImporter < Base
      CATEGORY = 'labels'
      MODEL = ::Label
      UNIQUE_FIELD = :title
    end
  end
end
