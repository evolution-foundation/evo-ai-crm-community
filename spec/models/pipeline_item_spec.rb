# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PipelineItem, type: :model do
  let(:pipeline) { Pipeline.create!(name: 'Test Pipeline', pipeline_type: 'sales', created_by: User.create!(email: 'test@example.com', name: 'Test User')) }
  let(:pipeline_stage) { PipelineStage.create!(pipeline: pipeline, name: 'Stage 1', position: 1) }
  let(:contact) { Contact.create!(name: 'Test Contact', email: 'contact@example.com') }

  describe 'validations' do
    it 'requires either conversation_id or contact_id' do
      item = PipelineItem.new(
        pipeline: pipeline,
        pipeline_stage: pipeline_stage
      )
      expect(item).not_to be_valid
      expect(item.errors[:base]).to include('Must have either conversation_id or contact_id')
    end

    it 'does not allow both conversation_id and contact_id' do
      conversation = Conversation.create!(
        inbox: Inbox.create!(name: 'Test Inbox'),
        contact: contact,
        contact_inbox: ContactInbox.create!(contact: contact, inbox: Inbox.create!(name: 'Test Inbox'))
      )
      item = PipelineItem.new(
        pipeline: pipeline,
        pipeline_stage: pipeline_stage,
        conversation: conversation,
        contact: contact
      )
      expect(item).not_to be_valid
      expect(item.errors[:base]).to include('Cannot have both conversation_id and contact_id')
    end

    it 'validates with contact_id only' do
      item = PipelineItem.new(
        pipeline: pipeline,
        pipeline_stage: pipeline_stage,
        contact: contact
      )
      expect(item).to be_valid
    end

    it 'validates with conversation_id only' do
      conversation = Conversation.create!(
        inbox: Inbox.create!(name: 'Test Inbox'),
        contact: contact,
        contact_inbox: ContactInbox.create!(contact: contact, inbox: Inbox.create!(name: 'Test Inbox'))
      )
      item = PipelineItem.new(
        pipeline: pipeline,
        pipeline_stage: pipeline_stage,
        conversation: conversation
      )
      expect(item).to be_valid
    end
  end

  describe 'orphaned item detection' do
    it 'detects orphaned item when contact is missing' do
      item = PipelineItem.create!(
        pipeline: pipeline,
        pipeline_stage: pipeline_stage,
        contact: contact
      )
      contact.destroy

      item.reload
      expect(item.contact_id).to be_present
      expect(item.contact).to be_nil
    end

    it 'detects orphaned item when conversation is missing' do
      inbox = Inbox.create!(name: 'Test Inbox')
      contact_inbox = ContactInbox.create!(contact: contact, inbox: inbox)
      conversation = Conversation.create!(
        inbox: inbox,
        contact: contact,
        contact_inbox: contact_inbox
      )
      item = PipelineItem.create!(
        pipeline: pipeline,
        pipeline_stage: pipeline_stage,
        conversation: conversation
      )
      conversation.destroy

      item.reload
      expect(item.conversation_id).to be_present
      expect(item.conversation).to be_nil
    end
  end

  describe 'serialization behavior' do
    it 'marks orphaned items correctly in serializer' do
      item = PipelineItem.create!(
        pipeline: pipeline,
        pipeline_stage: pipeline_stage,
        contact: contact
      )
      contact_id = contact.id
      contact.destroy

      item.reload
      serialized = PipelineItemSerializer.serialize(item, include_entity: false)
      expect(serialized[:is_orphaned]).to be true
      expect(serialized[:contact_id]).to eq(contact_id)
    end

    it 'does not mark valid items as orphaned' do
      item = PipelineItem.create!(
        pipeline: pipeline,
        pipeline_stage: pipeline_stage,
        contact: contact
      )

      serialized = PipelineItemSerializer.serialize(item, include_entity: false)
      expect(serialized[:is_orphaned]).to be false
    end
  end
end
