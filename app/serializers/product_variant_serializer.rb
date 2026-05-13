# frozen_string_literal: true

# ProductVariantSerializer - Optimized serialization for ProductVariant.
#
# `attributes_data` (DB column) is exposed as `attributes` in the API for
# UI friendliness — the original name clashes with
# ActiveRecord::AttributeMethods#attributes, but consumers don't see that.
module ProductVariantSerializer
  extend self

  def serialize(variant)
    {
      id: variant.id,
      product_id: variant.product_id,
      name: variant.name,
      sku: variant.sku,
      price_override: variant.price_override&.to_f,
      effective_price: variant.effective_price&.to_f,
      effective_currency: variant.effective_currency,
      stock_quantity: variant.stock_quantity,
      attributes: variant.attributes_data || {},
      position: variant.position,
      created_at: variant.created_at&.iso8601,
      updated_at: variant.updated_at&.iso8601
    }
  end

  def serialize_collection(variants)
    return [] unless variants

    variants.map { |variant| serialize(variant) }
  end
end
