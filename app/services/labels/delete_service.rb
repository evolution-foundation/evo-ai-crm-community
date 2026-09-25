class Labels::DeleteService
  pattr_initialize [:label_title!]

  # `tagged_with` finds the row case-insensitively (LOWER(name) ILIKE) while this
  # subtraction used to be exact, so "Urgente" was located and left in place when
  # the title was "urgente". Subtract the same way the finder matches.
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
