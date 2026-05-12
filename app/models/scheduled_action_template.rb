# frozen_string_literal: true

# == Schema Information
#
# Table name: scheduled_action_templates
#
#  id                    :bigint           not null, primary key
#  action_type           :string(50)       not null
#  created_by            :uuid             not null
#  default_delay_minutes :integer
#  description           :text
#  is_default            :boolean          default(FALSE)
#  is_public             :boolean          default(FALSE)
#  name                  :string           not null
#  payload               :jsonb            not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#
# Indexes
#
#  idx_templates_default                            (is_default)
#  idx_templates_public                             (is_public)
#  index_scheduled_action_templates_on_action_type  (action_type)
#

class ScheduledActionTemplate < ApplicationRecord
  # Associations
  belongs_to :creator, class_name: 'User', foreign_key: :created_by

  # Validations
  validates :name, presence: true
  validates :action_type, presence: true, inclusion: { in: ScheduledAction::ACTION_TYPES }
  validates :created_by, presence: true
  validates :payload, presence: true

  # Scopes
  scope :by_action_type, ->(type) { where(action_type: type) }
  scope :defaults, -> { where(is_default: true) }
  scope :public_templates, -> { where(is_public: true) }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_name, ->(name) { where('name ILIKE ?', "%#{name}%") }

  # Helper method to apply template to a ScheduledAction
  def apply_to_scheduled_action(attributes = {})
    {
      action_type: action_type,
      payload: payload.deep_dup,
      scheduled_for: attributes[:scheduled_for] || default_delay_minutes.minutes.from_now,
      template_id: id,
      **attributes
    }
  end

  # Create a ScheduledAction from this template
  def create_scheduled_action!(contact_id, attributes = {})
    action_attributes = apply_to_scheduled_action(attributes)

    ScheduledAction.create!(
      contact_id: contact_id,
      created_by: created_by,
      max_retries: 3,
      **action_attributes
    )
  end
end
