# frozen_string_literal: true

# Reviewed export: subject taxonomy labels materials; Meta IDs establish the binding.
class Instagram::AmhMaterialInventory
  def self.snapshot
    JSON.parse(Rails.root.join('config/instagram_amh_material_inventory.json').read)
  end

  def self.match(contract, mappings)
    account = contract.dig('identity', 'professional_account_id')
    scoped = mappings.select { |row| row['account'] == account }
    exact = scoped.select { |row| contract['ad_id'].present? && row['ad'] == contract['ad_id'] }
    media = scoped.select { |row| contract['media_id'].present? && row['media'] == contract['media_id'] }
    validate_consistency!(exact, media, contract)
    candidates = exact.presence || media
    return if candidates.empty?

    materials = candidates.pluck('material').uniq
    raise Instagram::AmhExecutor::Unavailable unless materials.one?

    [materials.first, exact.any? ? 'inventory_ad' : 'inventory_media']
  end

  def self.validate_consistency!(exact, media, contract)
    if exact.any? && contract['media_id'].present? && exact.any? { |row| row['media'] != contract['media_id'] }
      raise Instagram::AmhExecutor::Unavailable
    end
    return if exact.empty? || media.empty? || (exact.pluck('material') + media.pluck('material')).uniq.one?

    raise Instagram::AmhExecutor::Unavailable
  end
end
