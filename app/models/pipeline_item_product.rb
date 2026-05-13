# == Schema Information
#
# Table name: pipeline_item_products
#
#  id                 :uuid             not null, primary key
#  created_by_type    :string(50)
#  currency           :string(3)        not null
#  locked_unit_price  :decimal(10, 2)   not null
#  notes              :text
#  quantity           :integer          default(1), not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  created_by_id      :uuid
#  pipeline_item_id   :uuid             not null
#  product_id         :uuid             not null
#  product_variant_id :uuid
#
# Indexes
#
#  index_pipeline_item_products_on_creator             (created_by_type,created_by_id)
#  index_pipeline_item_products_on_pipeline_item_id    (pipeline_item_id)
#  index_pipeline_item_products_on_product_id          (product_id)
#  index_pipeline_item_products_on_product_variant_id  (product_variant_id)
#  index_pipeline_item_products_unique_combo           (pipeline_item_id,product_id,product_variant_id)
#
# Foreign Keys
#
#  fk_rails_...  (pipeline_item_id => pipeline_items.id) ON DELETE => cascade
#  fk_rails_...  (product_id => products.id) ON DELETE => restrict
#  fk_rails_...  (product_variant_id => product_variants.id) ON DELETE => restrict
#
class PipelineItemProduct < ApplicationRecord
  belongs_to :pipeline_item
  belongs_to :product
  belongs_to :product_variant, optional: true

  ALLOWED_CREATED_BY_TYPES = %w[User AutomationRule AiAgent].freeze

  validates :quantity, numericality: { greater_than: 0, only_integer: true }
  validates :locked_unit_price, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :currency, presence: true, length: { is: 3 }
  validates :created_by_type, inclusion: { in: ALLOWED_CREATED_BY_TYPES }, allow_nil: true
  validate :variant_belongs_to_product

  before_validation :snapshot_price_and_currency, on: :create

  def subtotal
    return 0 if quantity.blank? || locked_unit_price.blank?

    quantity * locked_unit_price
  end

  private

  def snapshot_price_and_currency
    return unless product

    self.locked_unit_price ||= (product_variant&.price_override || product.default_price)
    self.currency ||= product.currency
  end

  def variant_belongs_to_product
    return if product_variant.blank?
    return if product_id.blank?
    return if product_variant.product_id == product_id

    errors.add(:product_variant, 'must belong to the selected product')
  end
end
