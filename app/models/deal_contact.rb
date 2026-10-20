class DealContact < ApplicationRecord
  belongs_to :pipeline_item
  belongs_to :contact

  validates :contact_id, uniqueness: { scope: :pipeline_item_id }
end
