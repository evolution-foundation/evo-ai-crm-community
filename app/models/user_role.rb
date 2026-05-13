# frozen_string_literal: true

# == Schema Information
#
# Table name: user_roles
#
#  id            :uuid             not null, primary key
#  granted_at    :datetime
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  granted_by_id :uuid
#  role_id       :uuid             not null
#  user_id       :uuid             not null
#
# Indexes
#
#  index_user_roles_on_granted_at     (granted_at)
#  index_user_roles_on_granted_by_id  (granted_by_id)
#  index_user_roles_on_role_id        (role_id)
#  index_user_roles_on_user_id        (user_id)
#  index_user_roles_unique            (user_id,role_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (granted_by_id => users.id)
#  fk_rails_...  (role_id => roles.id)
#  fk_rails_...  (user_id => users.id)
#
class UserRole < ApplicationRecord
  # Evolution Reference Model - managed by evo-auth-service
  # This model serves only as a reference to sync data from evo-auth-service

  self.table_name = 'user_roles'

  belongs_to :user
  belongs_to :role
  belongs_to :granted_by, class_name: 'User', optional: true

  validates :user, presence: true
  validates :role, presence: true
end
