# frozen_string_literal: true

module BotRuntime
  # Best-effort delivery of a "customer is typing" signal — never retried,
  # never raised past this job. Worst case on failure is simply no debounce
  # extension for that pulse (see Whatsapp::PresenceEventFilter and the design
  # doc's error-handling section: presence is cosmetic end-to-end).
  class SendPresenceEventJob < ApplicationJob
    queue_as :bot_runtime

    def perform(event)
      BotRuntime::Client.new.send_presence_event(event)
    rescue StandardError => e
      Rails.logger.warn "[BotRuntime::SendPresenceEventJob] Failed (best-effort): #{e.message}"
    end
  end
end
