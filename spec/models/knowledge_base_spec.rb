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

  describe 'destroying an attached knowledge base' do
    let(:knowledge_base) { create(:knowledge_base) }
    let(:ai_agent_id) { SecureRandom.uuid }

    before do
      create(:ai_agent_knowledge_base, knowledge_base: knowledge_base, ai_agent_id: ai_agent_id)
      # The real Ai::AgentKnowledgeBaseSyncService calls out to evo_core over
      # HTTP; stub it so the after_destroy sync doesn't hit the network here.
      allow(EvoAiCoreService).to receive(:get_agent).and_return({ 'name' => 'Bot', 'type' => 'llm', 'config' => {} })
      allow(EvoAiCoreService).to receive(:update_agent)
    end

    it 'does not raise ActiveRecord::InvalidForeignKey and cascades the join row' do
      expect { knowledge_base.destroy! }.not_to raise_error
      expect(AiAgentKnowledgeBase.find_by(ai_agent_id: ai_agent_id)).to be_nil
    end

    it 're-syncs the previously attached agent so evo_core config is cleared' do
      sync_service = instance_double(Ai::AgentKnowledgeBaseSyncService, call: true)
      expect(Ai::AgentKnowledgeBaseSyncService).to receive(:new)
        .with(ai_agent_id: ai_agent_id)
        .and_return(sync_service)

      knowledge_base.destroy!

      expect(sync_service).to have_received(:call)
    end
  end
end
