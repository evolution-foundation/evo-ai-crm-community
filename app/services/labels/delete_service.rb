class Labels::DeleteService
  pattr_initialize [:label_title!]

  # Matches the way `tagged_with` finds the row (LOWER(name) ILIKE): an exact
  # subtraction leaves "Urgente" in place when removing "urgente".
  def self.without(label_list, title)
    label_list.to_a.reject { |applied| applied.to_s.casecmp?(title.to_s) }
  end

  def perform
    tagged_conversations.find_in_batches do |conversation_batch|
      conversation_batch.each do |conversation|
        # Route through the setter so the label_list change is dirty-tracked and
        # Conversation#create_label_change / notify_conversation_updation emit the
        # label.removed activity + CONVERSATION_UPDATED (a bare label_list.remove
        # mutates the collection without populating previous_changes[:label_list]).
        conversation.update!(label_list: self.class.without(conversation.label_list, label_title))
      end
    end

    tagged_contacts.find_in_batches do |contact_batch|
      contact_batch.each do |contact|
        # Route through the setter so saved_change_to_label_list? dirty-tracks
        # the removal and Contact#publish_label_changes emits the remove event.
        contact.update!(label_list: self.class.without(contact.label_list, label_title))
      end
    end
  end

  private

  def tagged_conversations
    Conversation.tagged_with(label_title)
  end

  def tagged_contacts
    Contact.tagged_with(label_title)
  end
end
