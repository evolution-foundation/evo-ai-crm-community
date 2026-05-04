# frozen_string_literal: true

# Role model - synced from evo-auth-service
# This model provides read-only access to roles managed by evo-auth-service
class Role < ApplicationRecord
  # Evolution Reference Model - managed by evo-auth-service
  # This model serves only as a reference to sync data from evo-auth-service

  self.table_name = 'roles'

  # Read-only model - data is synced from evo-auth-service
  has_many :user_roles, dependent: :destroy_async
  has_many :users, through: :user_roles

  validates :key, presence: true, uniqueness: true
  validates :name, presence: true

  # Check if this is an administrator role
  def administrator?
    key.in?(%w[account_owner administrator admin])
  end

  # Find administrator role
  def self.administrator_role
    find_by(key: %w[account_owner administrator admin])
  end

  # Find users with administrator roles
  def self.administrator_users
    Role.where(key: %w[account_owner administrator admin]).flat_map(&:users).uniq
  end
end
