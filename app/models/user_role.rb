# frozen_string_literal: true

# UserRole model - joins table for users and roles
# This model provides read-only access to user_roles managed by evo-auth-service
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
