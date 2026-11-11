# == Schema Information
#
# Table name: procedure_targets
#
#  id           :uuid             not null, primary key
#  target_type  :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  procedure_id :uuid             not null
#  target_id    :uuid             not null
#
# Indexes
#
#  idx_procedure_targets_unique_target                   (procedure_id,target_type,target_id) UNIQUE
#  index_procedure_targets_on_procedure_id               (procedure_id)
#  index_procedure_targets_on_target_type_and_target_id  (target_type,target_id)
#
# Foreign Keys
#
#  fk_rails_...  (procedure_id => procedures.id)
#
class ProcedureTarget < ApplicationRecord
  TARGET_TYPES = %w[label product inbox pipeline_stage].freeze

  belongs_to :procedure

  validates :target_type, presence: true, inclusion: { in: TARGET_TYPES }
  validates :target_id, presence: true
  validates :target_type, uniqueness: { scope: [:procedure_id, :target_id] }
end
