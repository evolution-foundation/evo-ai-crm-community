require 'rails_helper'

RSpec.describe Ai::AgentKnowledgeBaseSyncService do
  let(:knowledge_base) { create(:knowledge_base) }
  let(:ai_agent_id) { SecureRandom.uuid } # RULING (see ledger): ai_agent_id is a uuid column — a non-UUID string like 'agent-123' would fail Postgres insertion

  before do
    create(:ai_agent_knowledge_base, ai_agent_id: ai_agent_id, knowledge_base: knowledge_base, knowledge_tags: ['vendas'])
    allow(EvoAiCoreService).to receive(:get_agent).with(ai_agent_id, nil).and_return(
      { 'name' => 'Bot', 'type' => 'llm', 'config' => { 'load_memory' => true } }
    )
    allow(EvoAiCoreService).to receive(:update_agent)
  end

  it 'merges knowledge_base_id and knowledge_tags into the agent config without dropping other keys' do
    described_class.new(ai_agent_id: ai_agent_id).call

    expect(EvoAiCoreService).to have_received(:update_agent).with(
      ai_agent_id,
      hash_including(
        config: hash_including(
          'load_memory' => true,
          'load_knowledge' => true,
          'knowledge_base_id' => knowledge_base.id,
          'knowledge_tags' => ['vendas']
        )
      ),
      nil
    )
  end

  it 'sets load_knowledge to false when no knowledge base is attached' do
    AiAgentKnowledgeBase.destroy_all

    described_class.new(ai_agent_id: ai_agent_id).call

    expect(EvoAiCoreService).to have_received(:update_agent).with(
      ai_agent_id,
      hash_including(config: hash_including('load_knowledge' => false)),
      nil
    )
  end
end
