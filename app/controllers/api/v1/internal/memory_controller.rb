class Api::V1::Internal::MemoryController < Api::ServiceController
  include KnowledgeSearchParams

  before_action :require_app_name_and_user_id, only: %i[event search load compress clear]

  def event
    memory_event = MemoryEvent.create!(app_name: app_name, user_id: user_id, role: params[:role].to_s, content: params[:content].to_s)

    # Compression runs before the FIFO trim so that events about to be trimmed
    # still get a chance to land in a MemorySummary first; without this the
    # medium-term tier never populates and trim_to! silently drops history.
    maybe_compress

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

  # The processor sends compression_interval on every add_event call; when the
  # post-insert event count for this pair reaches it, roll the events up into a
  # MemorySummary. Only fires when the param is actually present, mirroring the
  # max_messages conditional.
  def maybe_compress
    return if params[:compression_interval].blank?

    interval = params[:compression_interval].to_i
    return unless interval.positive?
    return unless MemoryEvent.for(app_name: app_name, user_id: user_id).count >= interval

    Memory::CompressionService.new.compress!(app_name: app_name, user_id: user_id, force: false, interval: interval)
  end

  def matching_memories(app_name:, user_id:, query:, limit:)
    summaries = MemorySummary.for(app_name: app_name, user_id: user_id)
    # MemoryEvent.for is oldest-first (correct for transcript replay); recall
    # wants the most recent matches, so flip it for this consumer only.
    events = MemoryEvent.for(app_name: app_name, user_id: user_id).reorder(created_at: :desc, id: :desc)

    if query.present?
      # Escape %/_ so a literal wildcard in the query does not match broadly.
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
      summaries = summaries.where('content ILIKE ?', pattern)
      events = events.where('content ILIKE ?', pattern)
    end

    # Take up to `limit` of each tier, then merge newest-first, so a full page
    # of summaries can never starve events out of the truncation window.
    candidates = summaries.limit(limit).to_a + events.limit(limit).to_a
    candidates.sort_by { |record| [-record.created_at.to_f, -record.id] }
              .first(limit)
              .map { |record| record.is_a?(MemorySummary) ? serialize_summary(record) : serialize_event(record) }
  end

  def serialize_summary(summary)
    { content: summary.content, timestamp: summary.created_at.iso8601, metadata: { role: 'summary' } }
  end

  def serialize_event(event)
    { content: event.content, timestamp: event.created_at.iso8601, metadata: { role: event.role } }
  end
end
