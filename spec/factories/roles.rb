FactoryBot.define do
  factory :role do
    sequence(:key) { |n| "role_#{n}" }
    sequence(:name) { |n| "Role #{n}" }

    trait :administrator do
      key { 'administrator' }
      name { 'Administrator' }
    end

    trait :super_admin do
      key { 'super_admin' }
      name { 'Super Admin' }
    end

    trait :account_owner do
      key { 'account_owner' }
      name { 'Account Owner' }
    end

    trait :agent do
      key { 'agent' }
      name { 'Agent' }
    end
  end

  factory :user_role do
    association :user
    association :role

    trait :granted_by do
      association :granted_by, factory: :user
    end
  end
end
