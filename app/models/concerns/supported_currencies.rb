# Single source of truth for currency codes accepted across pipeline items,
# pipeline service definitions, and products -- previously three independent
# hardcoded arrays that had to be kept in sync by hand.
module SupportedCurrencies
  CODES = %w[BRL USD EUR GBP].freeze
end
