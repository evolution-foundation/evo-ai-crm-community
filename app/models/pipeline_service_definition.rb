# == Schema Information
#
# Table name: pipeline_service_definitions
#
#  id            :uuid             not null, primary key
#  active        :boolean          default(TRUE), not null
#  currency      :string(3)        default("BRL")
#  default_value :decimal(10, 2)   default(0.0), not null
#  description   :text
#  name          :string(255)      not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  pipeline_id   :uuid             not null
#
# Indexes
#
#  index_pipeline_service_definitions_on_active             (active)
#  index_pipeline_service_definitions_on_pipeline_and_name  (pipeline_id,name) UNIQUE
#  index_pipeline_service_definitions_on_pipeline_id        (pipeline_id)
#
# Foreign Keys
#
#  fk_rails_...  (pipeline_id => pipelines.id)
#
class PipelineServiceDefinition < ApplicationRecord
  belongs_to :pipeline

  validates :name, presence: true, length: { maximum: 255 }
  validates :name, uniqueness: { scope: [:pipeline_id] }
  validates :default_value, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :currency, presence: true, inclusion: { in: SupportedCurrencies::CODES }
  validates :pipeline_id, presence: true

  scope :active, -> { where(active: true) }
  scope :for_pipeline, ->(pipeline) { where(pipeline: pipeline) }

  def formatted_default_value
    case currency
    when 'EUR', 'BRL'
      format('%.2f', default_value).tr('.', ',')
    else
      format('%.2f', default_value)
    end
  end
end
