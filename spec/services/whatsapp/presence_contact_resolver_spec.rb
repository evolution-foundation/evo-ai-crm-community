# frozen_string_literal: true

require 'rails_helper'

# CRM-212 follow-up review finding: presence.update lookups were using the
# raw JID digits directly, while message ingestion stores ContactInbox#source_id
# via Whatsapp::PhoneNumberNormalizer.call (and can also drift by the nono
# dígito, per the fix in ContactInboxWithContactBuilder). A presence pulse for
# a DDD >= 31 Brazilian mobile (or a MX/AR number) would look up a source_id
# that was never stored, silently never firing.
RSpec.describe Whatsapp::PresenceContactResolver do
  let(:inbox) { instance_double(Inbox, contact_inboxes: contact_inboxes_relation) }
  let(:contact_inboxes_relation) { instance_double(ActiveRecord::Relation) }

  describe '.resolve_conversation' do
    context 'when the exact raw digits match an existing ContactInbox' do
      it 'returns its active conversation' do
        contact_inbox = instance_double(ContactInbox, conversations: conversations_relation('raw-match'))
        allow(contact_inboxes_relation).to receive(:find_by).with(source_id: '5511999999999').and_return(contact_inbox)

        expect(described_class.resolve_conversation(inbox, '5511999999999')).to eq('raw-match')
      end
    end

    context 'when only the normalized (nono dígito stripped) form matches' do
      it 'falls back to the normalized source_id' do
        # DDD 74 (>= 31): normalizer strips the nono dígito.
        raw = '5574999879409'
        normalized = '557499879409'
        contact_inbox = instance_double(ContactInbox, conversations: conversations_relation('normalized-match'))

        allow(contact_inboxes_relation).to receive(:find_by).with(source_id: raw).and_return(nil)
        allow(contact_inboxes_relation).to receive(:find_by).with(source_id: normalized).and_return(contact_inbox)

        expect(described_class.resolve_conversation(inbox, raw)).to eq('normalized-match')
      end
    end

    context 'when only the alternate nono-dígito form matches (drift case)' do
      it 'falls back to the 9-inserted alternate candidate' do
        # DDD 11 (< 31): canonical form always keeps the 9, but this raw JID
        # arrived missing it (the exact drift ContactInboxWithContactBuilder
        # already reconciles for message ingestion).
        raw = '551187654321'
        alternate = '5511987654321'
        contact_inbox = instance_double(ContactInbox, conversations: conversations_relation('alt-match'))

        allow(contact_inboxes_relation).to receive(:find_by).with(source_id: raw).and_return(nil)
        allow(contact_inboxes_relation).to receive(:find_by).with(source_id: alternate).and_return(contact_inbox)

        expect(described_class.resolve_conversation(inbox, raw)).to eq('alt-match')
      end
    end

    context 'when no candidate matches any ContactInbox' do
      it 'returns nil without raising' do
        allow(contact_inboxes_relation).to receive(:find_by).and_return(nil)

        expect(described_class.resolve_conversation(inbox, '5511999999999')).to be_nil
      end
    end
  end

  def conversations_relation(marker)
    where_chain = double('WhereChain', not: instance_double(ActiveRecord::Relation, last: marker))
    instance_double(ActiveRecord::Relation, where: where_chain)
  end
end
