class Api::V1::Internal::MemoryController < Api::ServiceController
  include KnowledgeSearchParams

  before_action :require_app_name_and_user_id, only: %i[event search load compress clear]

  def event
    memory_event = MemoryEvent.create!(app_name: app_name, user_id: user_id, role: params[:role].to_s, content: params[:content].to_s)

    if params[:max_messages].present?
      MemoryEvent.trim_to!(app_name: app_name, user_id: user_id, max_messages: params[:max_messages].to_i)
    end

    render json: { id: memory_event.id }, status: :created
  end

  def search
    query = params[:query].to_s
    limit = clamped_max_results(default: 10)

    memories = matching_memories(app_name: app_name, user_id: user_id, query: query, limit: limit)
    render json: { memories: memories, total: memories.size, query: query }
  end

  def load
    limit = clamped_max_results(default: 10)

    memories = MemorySummary.for(app_name: app_name, user_id: user_id).limit(limit).map { |s| serialize_summary(s) }
    render json: { memories: memories, total: memories.size, query: '' }
  end

  def compress
    summary = Memory::CompressionService.new.compress!(
      app_name: app_name,
      user_id: user_id,
      force: ActiveModel::Type::Boolean.new.cast(params[:force]) || false,
      interval: (params[:compression_interval] || params[:interval] || 10).to_i
    )

    if summary
      render json: { success: true, message: 'Memory compression completed', messages_compressed: summary.source_event_count, summary_id: summary.id, summary_content: summary.content }
    else
      render json: { success: false, message: 'Not enough events to compress', messages_compressed: 0 }
    end
  rescue Memory::CompressionService::Error => e
    render json: { error: e.message }, status: :bad_gateway
  end

  def clear
    MemoryEvent.for(app_name: app_name, user_id: user_id).delete_all
    MemorySummary.for(app_name: app_name, user_id: user_id).delete_all

    render json: { success: true }
  end

  private

  def app_name
    @app_name ||= params[:app_name].to_s
  end

  def user_id
    @user_id ||= params[:user_id].to_s
  end

  def require_app_name_and_user_id
    render json: { error: 'app_name and user_id are required' }, status: :bad_request if app_name.blank? || user_id.blank?
  end

  def matching_memories(app_name:, user_id:, query:, limit:)
    summaries = MemorySummary.for(app_name: app_name, user_id: user_id)
    events = MemoryEvent.for(app_name: app_name, user_id: user_id)

    if query.present?
      summaries = summaries.where('content ILIKE ?', "%#{query}%")
      events = events.where('content ILIKE ?', "%#{query}%")
    end

    (summaries.limit(limit).map { |s| serialize_summary(s) } + events.limit(limit).map { |e| serialize_event(e) }).first(limit)
  end

  def serialize_summary(summary)
    { content: summary.content, timestamp: summary.created_at.iso8601, metadata: { role: 'summary' } }
  end

  def serialize_event(event)
    { content: event.content, timestamp: event.created_at.iso8601, metadata: { role: event.role } }
  end
end
