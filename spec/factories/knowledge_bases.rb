FactoryBot.define do
  factory :knowledge_base do
    sequence(:name) { |n| "Knowledge Base #{n}" }
    active { true }
  end
end
