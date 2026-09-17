require 'net/http'
require 'json'

class Memory::CompressionService
  class Error < StandardError; end

  MODEL = 'gpt-4o-mini'
  DEFAULT_BASE_URL = 'https://api.openai.com/v1'

  def compress!(app_name:, user_id:, force: false, interval: 10)
    events = MemoryEvent.for(app_name: app_name, user_id: user_id)
    count = events.count
    return nil if count.zero?
    return nil if !force && count < interval

    transcript = events.map { |e| "#{e.role}: #{e.content}" }.join("\n")
    summary_text = call_llm(transcript)

    summary = MemorySummary.create!(
      app_name: app_name,
      user_id: user_id,
      content: summary_text,
      source_event_count: count
    )

    MemoryEvent.where(id: events.pluck(:id)).delete_all

    summary
  end

  private

  def call_llm(transcript)
    endpoint = Ai::CredentialResolver.resolve_endpoint(for_consumer: :memory_compression)
    raise Error, 'No OpenAI-compatible credential configured for memory compression' if endpoint.key.blank?

    uri = URI("#{endpoint.base_url.presence || DEFAULT_BASE_URL}/chat/completions")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'

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

    JSON.parse(response.body).dig('choices', 0, 'message', 'content').to_s.strip
  end
end
