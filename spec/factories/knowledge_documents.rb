FactoryBot.define do
  factory :knowledge_document do
    knowledge_base
    sequence(:title) { |n| "Document #{n}" }
    source_type { 'manual' }
    status { 'active' }
  end
end
