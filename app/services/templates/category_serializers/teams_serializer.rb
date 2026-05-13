# frozen_string_literal: true

module Templates
  module CategorySerializers
    # Teams shape only — team_members are not exported (would require user mapping).
    class TeamsSerializer < Base
      ALLOW_LIST = %w[name description allow_auto_assign].freeze
      SLUG_FIELD = :name
    end
  end
end
