# == Schema Information
#
# Table name: procedure_visibilities
#
#  id           :uuid             not null, primary key
#  scope_type   :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  procedure_id :uuid             not null
#  scope_id     :uuid
#
# Indexes
#
#  idx_procedure_visibilities_unique_global_scope           (procedure_id,scope_type) UNIQUE WHERE (scope_id IS NULL)
#  idx_procedure_visibilities_unique_scope                  (procedure_id,scope_type,scope_id) UNIQUE
#  index_procedure_visibilities_on_procedure_id             (procedure_id)
#  index_procedure_visibilities_on_scope_type_and_scope_id  (scope_type,scope_id)
#
# Foreign Keys
#
#  fk_rails_...  (procedure_id => procedures.id)
#
class ProcedureVisibility < ApplicationRecord
  SCOPE_TYPES = %w[all team inbox public_link].freeze

  belongs_to :procedure

  validates :scope_type, presence: true, inclusion: { in: SCOPE_TYPES }
  validates :scope_id, presence: true, if: -> { scope_type.in?(%w[team inbox]) }
  validates :scope_id, absence: true, if: -> { scope_type.in?(%w[all public_link]) }
  validates :scope_type, uniqueness: { scope: [:procedure_id, :scope_id] }
end
