# frozen_string_literal: true

# Whatsapp::PhoneNumberNormalizer
#
# Faithful port of Evolution API's `createJid` (evolution-api/src/utils/createJid.ts):
# the digit quirks the gateway applies to BR/MX/AR before talking to WhatsApp, so it
# says how the CHANNEL addresses a number, never how a contact stores it. Anything
# that does not match passes through with cosmetic cleanup only — it never raises.
class Whatsapp::PhoneNumberNormalizer
  def self.call(raw)
    new(raw).call
  end

  # The canonical form as E.164 ('+<digits>'), nil for blank input.
  def self.to_e164(raw)
    digits = call(raw)
    return nil if digits.blank?

    "+#{digits}"
  end

  # The number as informed, as E.164: cosmetic cleanup only, no digit dropped.
  def self.informed_e164(raw)
    new(raw).informed_e164
  end

  # Every E.164 form that resolves to the same canonical number, the informed one
  # first. Empty for blank input.
  def self.e164_variants(raw)
    new(raw).e164_variants
  end

  def initialize(raw)
    @raw = raw.to_s
  end

  # @return [String, nil] digits-only normalized number, or nil for blank input.
  def call
    return nil if @raw.strip.empty?

    number = strip_to_digits(@raw)
    return number if number.empty?

    number = format_mx_or_ar(number)
    format_br(number)
  end

  def informed_e164
    digits = strip_to_digits(@raw)
    digits.empty? ? nil : "+#{digits}"
  end

  def e164_variants
    canonical = call
    return [] if canonical.blank?

    [informed_e164, "+#{canonical}", expanded(canonical)].compact.uniq
  end

  private

  # The inverse of the two format_* below: the longer form that normalizes to
  # `canonical`, nil where the channel applies no quirk to it.
  def expanded(canonical)
    br = /\A55(\d{2})(\d{8})\z/.match(canonical)
    return "+55#{br[1]}9#{br[2]}" if br && br[1].to_i >= 31 && br[2][0].to_i >= 7

    extra = { '52' => '1', '54' => '9' }[canonical[0, 2]]
    "+#{canonical[0, 2]}#{extra}#{canonical[2..]}" if extra && canonical.length == 12
  end

  # Mirrors createJid's cleanup: drop whitespace, '+', parens, ':' suffix and any
  # JID domain, then keep only digits.
  def strip_to_digits(value)
    value.gsub(/\s/, '')
         .delete('+()')
         .split(':').first.to_s
         .split('@').first.to_s
         .gsub(/\D/, '')
  end

  # Port of formatMXOrARNumber: for MX (52) / AR (54), a 13-digit number carries
  # an extra leading digit right after the country code — drop it.
  def format_mx_or_ar(number)
    country_code = number[0, 2]
    return number unless %w[52 54].include?(country_code)
    return number unless number.length == 13

    country_code + number[3..]
  end

  # Port of formatBRNumber: regex ^(dd)(dd)\d(\d{8})$ — country, DDD, the nono
  # dígito (NOT captured), and the 8-digit subscriber number.
  #   keep the 9 when leading subscriber digit < 7 OR DDD < 31
  #   otherwise strip the 9
  def format_br(number)
    match = /\A(\d{2})(\d{2})\d(\d{8})\z/.match(number)
    return number unless match

    country, ddd, subscriber = match[1], match[2], match[3]
    return number unless country == '55'

    joker = subscriber[0].to_i
    return match[0] if joker < 7 || ddd.to_i < 31

    country + ddd + subscriber
  end
end
