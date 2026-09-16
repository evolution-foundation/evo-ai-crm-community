require 'rails_helper'

RSpec.describe Knowledge::Chunker do
  it 'returns the whole text as one chunk when under the limit' do
    chunker = described_class.new(max_chars: 100, overlap: 10)
    expect(chunker.chunks('short text')).to eq(['short text'])
  end

  it 'splits long text into overlapping chunks' do
    text = ('a' * 50) + ('b' * 50) + ('c' * 50)
    chunker = described_class.new(max_chars: 60, overlap: 10)

    chunks = chunker.chunks(text)

    expect(chunks.length).to be > 1
    expect(chunks.first.length).to be <= 60
    # overlap: end of chunk N should reappear at the start of chunk N+1
    expect(chunks[1]).to start_with(chunks[0][-10..])
  end

  it 'returns an empty array for blank input' do
    expect(described_class.new.chunks('')).to eq([])
    expect(described_class.new.chunks(nil)).to eq([])
  end
end
