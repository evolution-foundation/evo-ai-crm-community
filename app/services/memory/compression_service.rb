require 'net/http'
require 'json'
require 'zlib'

class Memory::CompressionService
  class Error < StandardError; end

  MODEL = 'gpt-4o-mini'
  DEFAULT_BASE_URL = 'https://api.openai.com/v1'
  OPEN_TIMEOUT = 10
  READ_TIMEOUT = 30

  def compress!(app_name:, user_id:, force: false, interval: 10)
    summary = nil

    ActiveRecord::Base.transaction do
      lock_key = Zlib.crc32("#{app_name}:#{user_id}")
      # Non-blocking: this transaction wraps an LLM call that can take
      # OPEN_TIMEOUT + READ_TIMEOUT seconds, and a blocking lock would pin a
      # second pooled connection idle for that whole window. A lost race means
      # someone else is already compressing these events, so bail out exactly
      # like "nothing to compress" — nil, no LLM call, no summary, no deletion.
      acquired = ActiveRecord::Base.connection.select_value("SELECT pg_try_advisory_xact_lock(#{lock_key})")
      next unless ActiveModel::Type::Boolean.new.cast(acquired)

      events = MemoryEvent.for(app_name: app_name, user_id: user_id).to_a
      count = events.size
      next if count.zero?
      next if !force && count < interval

      transcript = events.map { |e| "#{e.role}: #{e.content}" }.join("\n")
      summary_text = call_llm(transcript)

      summary = MemorySummary.create!(
        app_name: app_name,
        user_id: user_id,
        content: summary_text,
        source_event_count: count
      )

      MemoryEvent.where(id: events.map(&:id)).delete_all
    end

    summary
  end

  private

  def call_llm(transcript)
    endpoint = Ai::CredentialResolver.resolve_endpoint(for_consumer: :memory_compression)
    raise Error, 'No OpenAI-compatible credential configured for memory compression' if endpoint.key.blank?

    uri = URI("#{endpoint.base_url.presence || DEFAULT_BASE_URL}/chat/completions")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT

    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['Authorization'] = "Bearer #{endpoint.key}"
    request.body = {
      model: MODEL,
      messages: [
        { role: 'system', content: 'Summarize the following conversation into a concise paragraph capturing key facts, decisions, and context. Do not add commentary.' },
        { role: 'user', content: transcript }
      ]
    }.to_json

    response = http.request(request)
    raise Error, "Compression LLM call returned #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    begin
      JSON.parse(response.body).dig('choices', 0, 'message', 'content').to_s.strip
    rescue JSON::ParserError => e
      raise Error, "Compression LLM call returned unparseable JSON: #{e.message}"
    end
  end
end
