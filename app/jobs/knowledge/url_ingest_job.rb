class Knowledge::UrlIngestJob < ApplicationJob
  queue_as :low

  def perform(document, include_subpages:, max_pages:)
    pages = Knowledge::UrlCrawlService.new(document.source_url, include_subpages: include_subpages, max_pages: max_pages).call
    combined_text = pages.map { |p| p[:text] }.join("\n\n")
    document.update!(metadata: document.metadata.merge('raw_content' => combined_text, 'pages_crawled' => pages.length))
    Knowledge::IngestionService.new(document).call
  rescue StandardError => e
    document.update!(status: 'failed', last_error: e.message)
  end
end
