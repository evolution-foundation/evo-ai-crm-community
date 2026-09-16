class Knowledge::IngestionService
  def initialize(document, chunker: Knowledge::Chunker.new, embedder: Knowledge::EmbeddingService.new)
    @document = document
    @chunker = chunker
    @embedder = embedder
  end

  def call
    content = @document.metadata['raw_content'].to_s
    chunks = @chunker.chunks(content)

    @document.knowledge_entries.destroy_all

    chunks.each_with_index do |chunk, index|
      embedding = @embedder.embed(chunk)
      @document.knowledge_entries.create!(
        knowledge_base: @document.knowledge_base,
        chunk_index: index,
        content: chunk,
        tags: @document.tags,
        embedding: embedding
      )
    end

    @document.update!(status: 'active', last_error: nil)
  rescue StandardError => e
    @document.update!(status: 'failed', last_error: e.message)
  end
end
