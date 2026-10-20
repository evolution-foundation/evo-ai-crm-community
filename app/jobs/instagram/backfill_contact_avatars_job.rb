# frozen_string_literal: true

class Instagram::BackfillContactAvatarsJob < ApplicationJob
  queue_as :low

  BATCH_SIZE = 100

  def perform(inbox_id, after_id = nil)
    inbox = Inbox.find_by(id: inbox_id)
    return unless inbox&.instagram?

    batch = contact_inbox_batch(inbox_id, after_id)
    batch.each do |contact_inbox|
      next if contact_inbox.contact.avatar.attached?

      Instagram::FetchContactAvatarJob.perform_later(contact_inbox.id)
    end

    self.class.perform_later(inbox_id, batch.last.id) if batch.size == BATCH_SIZE
  end

  private

  def contact_inbox_batch(inbox_id, after_id)
    scope = ContactInbox.includes(contact: :avatar_attachment)
                        .where(inbox_id: inbox_id)
                        .order(:id)
    scope = scope.where('contact_inboxes.id > ?', after_id) if after_id
    scope.limit(BATCH_SIZE).to_a
  end
end
