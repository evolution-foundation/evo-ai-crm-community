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

  # Roles that count as administrative for CRM-side bypasses (inbox
  # visibility, audit log access, etc). `super_admin` is the installation
  # owner introduced by the auth-service rename — must be present here so
  # the bootstrap user keeps admin-level access in the CRM.
  ADMIN_ROLE_KEYS = %w[super_admin account_owner administrator admin].freeze

  # Check if this is an administrator role
  def administrator?
    key.in?(ADMIN_ROLE_KEYS)
  end

  # Find administrator role
  def self.administrator_role
    find_by(key: ADMIN_ROLE_KEYS)
  end

  # Find users with administrator roles
  def self.administrator_users
    Role.where(key: ADMIN_ROLE_KEYS).flat_map(&:users).uniq
  end
end
