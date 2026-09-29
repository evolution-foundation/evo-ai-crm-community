# frozen_string_literal: true

module BotRuntime
  # Forwards a "customer is typing" signal to evo-bot-runtime so it can renew
  # an in-flight debounce timer. Carries no message content — see
  # docs/superpowers/specs/2026-09-28-whatsapp-inbound-typing-debounce-design.md.
  class PresenceDelegationService
    def initialize(conversation)
      @conversation = conversation
    end

    def delegate
      return unless BotRuntime::Config.enabled?

      BotRuntime::SendPresenceEventJob.perform_later(
        contact_id: BotRuntime::StableContactId.stable_contact_id(@conversation.contact_id),
        conversation_id: @conversation.display_id
      )
    end
  end
end
