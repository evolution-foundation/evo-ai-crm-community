# frozen_string_literal: true

class Instagram::AmhDispatchJob < ApplicationJob
  queue_as :default
  retry_on Instagram::AmhConfirmation::NotReady, wait: 1.second, attempts: 5

  def perform(event_id)
    event = Instagram::AmhInboundEvent.find(event_id)
    return Instagram::AmhConfirmation.call(event: event) if event.contract['amh_confirmation'].present?

    Instagram::AmhVisualProof.where(audience: %w[test active]).find_each do |proof|
      Instagram::AmhExecutor.call(event: event, proof: proof)
    rescue Instagram::AmhExecutor::Unavailable
      next
    end
  rescue Instagram::AmhExecutor::Unavailable
    nil
  end
end
