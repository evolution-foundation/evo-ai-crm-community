# frozen_string_literal: true

# PipelineItemProductSerializer - serializes the link between a
# pipeline_item and a product (a recorded sale).
module PipelineItemProductSerializer
  extend self

  def serialize(link)
    {
      id: link.id,
      pipeline_item_id: link.pipeline_item_id,
      product_id: link.product_id,
      product_variant_id: link.product_variant_id,
      product: link.product ? minimal_product(link.product) : nil,
      product_variant: link.product_variant ? minimal_variant(link.product_variant) : nil,
      quantity: link.quantity,
      locked_unit_price: link.locked_unit_price&.to_f,
      currency: link.currency,
      subtotal: link.subtotal&.to_f,
      notes: link.notes,
      created_by_type: link.created_by_type,
      created_by_id: link.created_by_id,
      created_at: link.created_at&.iso8601,
      updated_at: link.updated_at&.iso8601
    }
  end

  def serialize_collection(links)
    return [] unless links

    links.map { |link| serialize(link) }
  end

  private

  def minimal_product(product)
    {
      id: product.id,
      name: product.name,
      kind: product.kind,
      sku: product.sku,
      currency: product.currency
    }
  end

  def minimal_variant(variant)
    {
      id: variant.id,
      name: variant.name,
      sku: variant.sku
    }
  end
end
