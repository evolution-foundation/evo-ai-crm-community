# frozen_string_literal: true

module ProcedureSerializer
  extend self

  def serialize(procedure, include_public_token: false)
    payload = {
      id: procedure.id,
      title: procedure.title,
      description: procedure.description,
      category: procedure.category,
      tags: procedure.tags || [],
      status: procedure.status,
      usage_mode: procedure.usage_mode,
      content_blocks: procedure.content_blocks || [],
      metadata: procedure.metadata || {},
      published_at: procedure.published_at&.iso8601,
      archived_at: procedure.archived_at&.iso8601,
      created_by_id: procedure.created_by_id,
      updated_by_id: procedure.updated_by_id,
      visibility: procedure.procedure_visibilities.map { |visibility| serialize_visibility(visibility) },
      targets: procedure.procedure_targets.map { |target| serialize_target(target) },
      attachments: procedure.attachments.map(&:push_event_data).compact,
      created_at: procedure.created_at&.iso8601,
      updated_at: procedure.updated_at&.iso8601
    }
    payload[:public_token] = procedure.public_token if include_public_token
    payload
  end

  def serialize_collection(procedures, include_public_token: false)
    return [] unless procedures

    procedures.map { |procedure| serialize(procedure, include_public_token: include_public_token) }
  end

  private

  def serialize_visibility(visibility)
    {
      id: visibility.id,
      scope_type: visibility.scope_type,
      scope_id: visibility.scope_id
    }
  end

  def serialize_target(target)
    {
      id: target.id,
      target_type: target.target_type,
      target_id: target.target_id
    }
  end
end
