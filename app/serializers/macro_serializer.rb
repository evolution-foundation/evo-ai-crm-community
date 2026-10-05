# frozen_string_literal: true

# MacroSerializer - Optimized serialization for Macro resources
#
# Plain Ruby module for Oj direct serialization
#
# Usage:
#   MacroSerializer.serialize(@macro)
#
module MacroSerializer
  extend self

  # Serialize single Macro
  #
  # @param macro [Macro] Macro to serialize
  # @param options [Hash] Serialization options
  #
  # @return [Hash] Serialized macro ready for Oj
  #
  def serialize(macro)
    {
      id: macro.id,
      name: macro.name,
      visibility: macro.visibility,
      actions: macro.actions,
      files: macro.file_base_data,
      created_by_id: macro.created_by_id,
      updated_by_id: macro.updated_by_id,
      created_at: macro.created_at&.iso8601,
      updated_at: macro.updated_at&.iso8601
    }
  end

  # Serialize collection of Macros
  #
  # @param macros [Array<Macro>, ActiveRecord::Relation]
  #
  # @return [Array<Hash>] Array of serialized macros
  #
  def serialize_collection(macros)
    return [] unless macros

    macros.map { |macro| serialize(macro) }
  end
end
