# frozen_string_literal: true

module BotRuntime
  # Generates a deterministic int64 from a contact id, used as the wire
  # identifier both BotRuntime::DelegationService (per-message events) and
  # BotRuntime::PresenceDelegationService (typing signals) send to
  # evo-bot-runtime — both must resolve to the exact same pipeline key for a
  # given contact/conversation pair.
  module StableContactId
    module_function

    # Uses SHA256 truncated to 8 bytes, masked to positive int64.
    # Deterministic across processes and restarts (unlike String#hash).
    def stable_contact_id(contact_id)
      digest = Digest::SHA256.digest(contact_id.to_s)
      digest.unpack1('Q>') & 0x7FFFFFFFFFFFFFFF
    end
  end
end
