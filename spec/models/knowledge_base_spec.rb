require 'rails_helper'

RSpec.describe KnowledgeBase, type: :model do
  it 'is valid with a name' do
    kb = described_class.new(name: 'evoai')
    expect(kb).to be_valid
  end

  it 'requires a name' do
    kb = described_class.new(name: nil)
    expect(kb).not_to be_valid
  end

  it 'unsets the previous default when a new default is saved' do
    first = FactoryBot.create(:knowledge_base, default: true)
    second = FactoryBot.create(:knowledge_base, default: true)

    expect(first.reload.default).to be false
    expect(second.reload.default).to be true
  end
end
