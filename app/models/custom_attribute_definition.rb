# == Schema Information
#
# Table name: custom_attribute_definitions
#
#  id                     :uuid             not null, primary key
#  attribute_description  :text
#  attribute_display_name :string
#  attribute_display_type :integer          default("text")
#  attribute_key          :string
#  attribute_model        :integer          default("conversation_attribute")
#  attribute_values       :jsonb
#  default_value          :integer
#  regex_cue              :string
#  regex_pattern          :string
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#
# Indexes
#
#  attribute_key_model_index  (attribute_key,attribute_model) UNIQUE
#
class CustomAttributeDefinition < ApplicationRecord
  include Events::Types

  STANDARD_ATTRIBUTES = {
    :conversation => %w[status priority assignee_id inbox_id team_id display_id campaign_id labels browser_language country_code referer created_at
                        last_activity_at channel_type],
    :contact => %w[name email phone_number identifier country_code city created_at last_activity_at referer blocked],
    :pipeline => %w[id name description pipeline_type visibility is_active config created_at updated_at created_by_id],
    :pipeline_stage => %w[id name position color stage_type automation_rules created_at updated_at pipeline_id],
    :pipeline_item => %w[pipeline_id conversation_id pipeline_stage_id custom_fields created_at updated_at contact_id]
  }.freeze

  scope :with_attribute_model, ->(attribute_model) { attribute_model.presence && where(attribute_model: attribute_model) }

  validates :attribute_display_name, presence: true

  validates :attribute_key,
            presence: true,
            uniqueness: { scope: [:attribute_model] }

  validates :attribute_display_type, presence: true
  validates :attribute_model, presence: true
  validate :attribute_must_not_conflict, on: :create

  enum attribute_model: {
    conversation_attribute: 0,
    contact_attribute: 1,
    pipeline_attribute: 2,
    pipeline_stage_attribute: 3,
    pipeline_item_attribute: 4
  }
  enum attribute_display_type: { text: 0, number: 1, currency: 2, percent: 3, link: 4, date: 5, list: 6, checkbox: 7, datetime: 8 }

  # Widget pre-chat sync trigger chain:
  # - create: sync metadata to matching pre-chat fields (if any) + dispatch event
  # - update: sync metadata to matching pre-chat fields + dispatch event
  # - destroy: remove matching pre-chat fields + dispatch event
  after_create_commit :sync_widget_pre_chat_custom_fields_on_create, :dispatch_create_event
  after_update_commit :update_widget_pre_chat_custom_fields, :dispatch_update_event
  after_destroy_commit :sync_widget_pre_chat_custom_fields, :dispatch_destroy_event

  private

  def sync_widget_pre_chat_custom_fields_on_create
    return unless should_sync_widget_pre_chat_custom_fields?

    ::Inboxes::UpdateWidgetPreChatCustomFieldsJob.perform_later(self)
  end

  def sync_widget_pre_chat_custom_fields
    return unless should_sync_widget_pre_chat_custom_fields?

    ::Inboxes::SyncWidgetPreChatCustomFieldsJob.perform_later(attribute_key)
  end

  def update_widget_pre_chat_custom_fields
    return unless should_sync_widget_pre_chat_custom_fields?

    ::Inboxes::UpdateWidgetPreChatCustomFieldsJob.perform_later(self)
  end

  def should_sync_widget_pre_chat_custom_fields?
    contact_attribute? || conversation_attribute?
  end

  def attribute_must_not_conflict
    model_keys = case attribute_model.to_sym
                 when :conversation_attribute then :conversation
                 when :contact_attribute then :contact
                 when :pipeline_attribute then :pipeline
                 when :pipeline_stage_attribute then :pipeline_stage
                 when :pipeline_item_attribute then :pipeline_item
                 end
    return unless model_keys && attribute_key.in?(STANDARD_ATTRIBUTES[model_keys])

    errors.add(:attribute_key, I18n.t('errors.custom_attribute_definition.key_conflict'))
  end

  def dispatch_create_event
    Rails.configuration.dispatcher.dispatch(CUSTOM_ATTRIBUTE_DEFINITION_CREATED, Time.zone.now, custom_attribute_definition: self)
  end

  def dispatch_update_event
    Rails.configuration.dispatcher.dispatch(CUSTOM_ATTRIBUTE_DEFINITION_UPDATED, Time.zone.now, custom_attribute_definition: self, saved_changes: saved_changes)
  end

  def dispatch_destroy_event
    Rails.configuration.dispatcher.dispatch(CUSTOM_ATTRIBUTE_DEFINITION_DELETED, Time.zone.now, custom_attribute_definition: self)
  end
end
