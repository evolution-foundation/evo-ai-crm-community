# == Schema Information
#
# Table name: ai_agent_products
#
#  id          :uuid             not null, primary key
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  ai_agent_id :uuid             not null
#  product_id  :uuid             not null
#
# Indexes
#
#  index_ai_agent_products_on_ai_agent_id  (ai_agent_id)
#  index_ai_agent_products_on_product_id   (product_id)
#  index_ai_agent_products_unique          (ai_agent_id,product_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (product_id => products.id) ON DELETE => cascade
#
class AiAgentProduct < ApplicationRecord
  belongs_to :product

  validates :ai_agent_id, presence: true
  validates :ai_agent_id, uniqueness: { scope: :product_id }
end
