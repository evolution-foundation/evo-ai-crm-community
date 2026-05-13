# frozen_string_literal: true

module Templates
  # Temporarily replaces Rails.configuration.dispatcher with a NullDispatcher
  # so bulk import does not broadcast events for each created entity.
  module DispatcherSuppression
    def self.with_suppressed
      original = Rails.configuration.dispatcher
      Rails.configuration.dispatcher = NullDispatcher.new
      yield
    ensure
      Rails.configuration.dispatcher = original
    end
  end
end
