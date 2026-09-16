require 'rails_helper'

RSpec.describe Knowledge::IngestionService do
  let(:knowledge_base) { create(:knowledge_base) }
  let(:document) do
    create(
      :knowledge_document,
      knowledge_base: knowledge_base,
      status: 'processing',
      metadata: { 'raw_content' => 'a' * 9000 },
      tags: ['vendas']
    )
  end

  before do
    allow_any_instance_of(Knowledge::EmbeddingService).to receive(:embed).and_return(Array.new(1536, 0.1))
  end

  it 'creates one KnowledgeEntry per chunk, tagged like the document' do
    described_class.new(document).call

    expect(document.knowledge_entries.count).to be > 1
    expect(document.knowledge_entries.first.tags).to eq(['vendas'])
    expect(document.knowledge_entries.first.embedding).not_to be_nil
  end

  it 'marks the document active on success' do
    described_class.new(document).call
    expect(document.reload.status).to eq('active')
  end

  it 'marks the document failed and records the error when embedding raises' do
    allow_any_instance_of(Knowledge::EmbeddingService).to receive(:embed).and_raise(Knowledge::EmbeddingService::Error, 'rate limited')

    described_class.new(document).call

    expect(document.reload.status).to eq('failed')
    expect(document.last_error).to include('rate limited')
  end
end
