# frozen_string_literal: true

# == Schema Information
#
# Table name: evo_core_custom_mcp_servers
#
#  id          :uuid             not null, primary key
#  description :text
#  headers     :json             not null
#  name        :string(255)      not null
#  retry_count :integer          default(0), not null
#  tags        :string(255)      default([]), not null, is an Array
#  timeout     :integer          default(0), not null
#  tools       :json             not null
#  url         :string(1024)     not null
#  created_at  :timestamptz
#  updated_at  :timestamptz
#
# Indexes
#
#  idx_evo_core_custom_mcp_servers_name         (name)
#  idx_evo_core_custom_mcp_servers_name_unique  (name) UNIQUE
#
# Read-only view over `evo_core_custom_mcp_servers`.
# See Ai::CustomTool for why these views exist.
class Ai::CustomMcpServer < ActiveRecord::Base # rubocop:disable Rails/ApplicationRecord -- write-path validations make no sense on a read-only view of a foreign table
  self.table_name = 'evo_core_custom_mcp_servers'

  scope :active, -> { where(is_active: true) }

  def readonly?
    true
  end
end
