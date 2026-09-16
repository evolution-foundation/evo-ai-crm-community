class Knowledge::IngestJob < ApplicationJob
  queue_as :low

  def perform(document)
    Knowledge::IngestionService.new(document).call
  end
end
