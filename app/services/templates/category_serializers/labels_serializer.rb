# frozen_string_literal: true

module Templates
  module CategorySerializers
    class LabelsSerializer < Base
      ALLOW_LIST = %w[title description color show_on_sidebar].freeze
      SLUG_FIELD = :title
    end
  end
end
