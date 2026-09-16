# frozen_string_literal: true

# == Schema Information
#
# Table name: evo_core_custom_tools
#
#  id             :uuid             not null, primary key
#  body_params    :json             not null
#  description    :text
#  endpoint       :string(1024)     not null
#  error_handling :json             not null
#  examples       :string(255)      default([]), not null, is an Array
#  headers        :json             not null
#  input_modes    :string(255)      default([]), not null, is an Array
#  method         :string(10)       not null
#  name           :string(255)      not null
#  output_modes   :string(255)      default([]), not null, is an Array
#  path_params    :json             not null
#  query_params   :json             not null
#  tags           :string(255)      default([]), not null, is an Array
#  values         :json             not null
#  created_at     :timestamptz
#  updated_at     :timestamptz
#
# Indexes
#
#  idx_evo_core_custom_tools_name         (name)
#  idx_evo_core_custom_tools_name_unique  (name) UNIQUE
#
# Read-only view over `evo_core_custom_tools`. Same arrangement as
# Ai::IntegrationCredential: the core owns the table, the CRM only reads it.
class Ai::CustomTool < ActiveRecord::Base # rubocop:disable Rails/ApplicationRecord -- write-path validations make no sense on a read-only view of a foreign table
  self.table_name = 'evo_core_custom_tools'

  scope :active, -> { where(is_active: true) }

  def readonly?
    true
  end
end
