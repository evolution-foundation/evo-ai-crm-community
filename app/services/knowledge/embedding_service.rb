require 'net/http'
require 'json'

class Knowledge::EmbeddingService
  class Error < StandardError; end

  MODEL = 'text-embedding-3-small'
  DEFAULT_BASE_URL = 'https://api.openai.com/v1'

  def embed(text, model: GlobalConfigService.load('KNOWLEDGE_EMBEDDING_MODEL', MODEL))
    raise Error, 'content is blank' if text.blank?

    endpoint = Ai::CredentialResolver.resolve_endpoint(for_consumer: :knowledge_embedding)
    raise Error, 'No OpenAI-compatible credential configured for knowledge embeddings' if endpoint.key.blank?

    response = post(text, model, endpoint)
    raise Error, "OpenAI embeddings API returned #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body).dig('data', 0, 'embedding')
  end

  private

  def post(text, model, endpoint)
    uri = URI("#{endpoint.base_url.presence || DEFAULT_BASE_URL}/embeddings")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'

    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['Authorization'] = "Bearer #{endpoint.key}"
    request.body = { model: model, input: text }.to_json

    http.request(request)
  end
end
