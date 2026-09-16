require 'rails_helper'

RSpec.describe KnowledgeEntry, type: :model do
  let(:knowledge_base) { create(:knowledge_base) }
  let(:document) { create(:knowledge_document, knowledge_base: knowledge_base) }

  it 'denormalizes knowledge_base_id from the document' do
    entry = described_class.create!(knowledge_document: document, content: 'hello world')
    expect(entry.knowledge_base_id).to eq(knowledge_base.id)
  end

  it 'finds entries by cosine distance, nearest first' do
    near = described_class.create!(
      knowledge_document: document, content: 'near', embedding: Array.new(1536, 0.1)
    )
    far = described_class.create!(
      knowledge_document: document, content: 'far', embedding: Array.new(1536) { |i| i.even? ? 0.9 : -0.9 }
    )

    results = described_class.search(
      knowledge_base_id: knowledge_base.id,
      query_embedding: Array.new(1536, 0.1),
      limit: 5
    )

    expect(results.first).to eq(near)
    expect(results.last).to eq(far)
  end

  it 'filters by tag when tags are given' do
    tagged = described_class.create!(
      knowledge_document: document, content: 'tagged', tags: ['vendas'], embedding: Array.new(1536, 0.1)
    )
    described_class.create!(
      knowledge_document: document, content: 'untagged', embedding: Array.new(1536, 0.1)
    )

    results = described_class.search(
      knowledge_base_id: knowledge_base.id,
      query_embedding: Array.new(1536, 0.1),
      tags: ['vendas']
    )

    expect(results.to_a).to eq([tagged])
  end
end
