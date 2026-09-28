# frozen_string_literal: true

# Whatsapp::PresenceContactResolver
#
# Resolves a presence webhook's raw sender id to the conversation whose
# debounce should be extended. Shared by Evolution and Evolution Go's
# presence handlers (WAHA already normalizes its own chat id before lookup
# and additionally respects lock_to_single_conversation, so it keeps its own
# inline resolution rather than using this).
#
# Message ingestion stores ContactInbox#source_id via
# Whatsapp::PhoneNumberNormalizer.call, and can itself have drifted by the
# nono dígito (see ContactInboxWithContactBuilder). A presence lookup using
# only the raw JID digits misses every DDD >= 31 Brazilian mobile (and MX/AR
# 13-digit numbers) whose stored source_id is the *normalized* form — this
# tries every plausible candidate before giving up.
module Whatsapp::PresenceContactResolver
  module_function

  def resolve_conversation(inbox, raw_number)
    contact_inbox = find_contact_inbox(inbox, raw_number)
    return unless contact_inbox

    contact_inbox.conversations.where.not(status: :resolved).last
  end

  def find_contact_inbox(inbox, raw_number)
    source_id_candidates(raw_number).each do |candidate|
      found = inbox.contact_inboxes.find_by(source_id: candidate)
      return found if found
    end
    nil
  end

  def source_id_candidates(raw_number)
    normalized = Whatsapp::PhoneNumberNormalizer.call(raw_number)
    alternates = Whatsapp::PhoneNumberNormalizer.to_e164_candidates(raw_number).map { |e164| e164.delete_prefix('+') }

    ([raw_number, normalized] + alternates).compact.uniq
  end
end
