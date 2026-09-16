FactoryBot.define do
  factory :ai_agent_knowledge_base do
    ai_agent_id { SecureRandom.uuid }
    knowledge_base
    knowledge_tags { [] }
  end
end
