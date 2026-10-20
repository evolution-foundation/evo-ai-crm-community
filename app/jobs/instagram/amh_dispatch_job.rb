# frozen_string_literal: true

class Instagram::AmhDispatchJob < ApplicationJob
  queue_as :default

  def perform(event_id)
    event = Instagram::AmhInboundEvent.find(event_id)
    Instagram::AmhVisualProof.where(audience: %w[test active]).find_each do |proof|
      Instagram::AmhExecutor.call(event: event, proof: proof)
    rescue Instagram::AmhExecutor::Unavailable
      next
    end
  end
end
