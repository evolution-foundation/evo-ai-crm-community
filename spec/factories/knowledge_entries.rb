FactoryBot.define do
  factory :knowledge_entry do
    knowledge_document
    sequence(:content) { |n| "Knowledge entry content #{n}" }
    tags { [] }
    embedding { Array.new(1536, 0.0) }
  end
end
