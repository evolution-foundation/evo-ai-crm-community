# frozen_string_literal: true

# Whatsapp::PhoneNumberNormalizer
#
# Single source of truth for normalizing a phone number into the canonical form
# WhatsApp itself resolves to. This is a faithful port of Evolution API's
# `createJid` logic (evolution-api/src/utils/createJid.ts) — the same rules the
# gateway applies before talking to WhatsApp — so that contacts created in the
# CRM (leads API, widget, import) and contacts seen via inbound WhatsApp messages
# converge on ONE string and stop duplicating.
#
# Covers the three countries with an "extra digit" quirk:
#   - Brazil (+55):  the nono dígito. Kept for DDD <= 30 (or landline-leading
#                    numbers); stripped for DDD >= 31 mobiles.
#   - Mexico (+52):  the leading "1" after the country code on 13-digit numbers.
#   - Argentina (+54): the leading "9" after the country code on 13-digit numbers.
#
# Returns DIGITS ONLY (no '+', no '@s.whatsapp.net'). Callers that persist E.164
# prepend '+' themselves; callers that build a JID append the suffix.
#
# Numbers from any other country, group JIDs, or strings that don't match the
# expected shape are returned with only cosmetic cleanup (non-digits removed),
# i.e. the function is a safe pass-through — never raises.
class Whatsapp::PhoneNumberNormalizer
  def self.call(raw)
    new(raw).call
  end

  # Convenience for lookup/persist paths that store E.164 ('+<digits>'). Returns
  # nil for blank/uninormalizable input so callers can guard a find_by cleanly.
  def self.to_e164(raw)
    digits = call(raw)
    return nil if digits.blank?

    "+#{digits}"
  end

  # A BR number that arrives missing its nono dígito entirely (12 digits) is
  # indistinguishable from one that never had it: `call` can only decide
  # whether to keep/strip the 9 when it's actually present (13-digit input).
  # For lookups (never for persistence) this returns every E.164 form the
  # same phone could canonicalize to, so a stored contact isn't missed just
  # because a webhook dropped or added the 9 in transit.
  def self.to_e164_candidates(raw)
    digits = call(raw)
    return [] if digits.blank?

    ([digits] + br_ninth_digit_alternate(digits)).uniq.map { |d| "+#{d}" }
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

  private

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

  # Given an already-normalized BR number, returns the other digit-count form
  # (9 inserted if missing, 9 removed if present) so a lookup can try both.
  # No-op for non-BR numbers.
  def self.br_ninth_digit_alternate(digits)
    return [] unless digits.start_with?('55')

    prefix = digits[0, 4]
    rest = digits[4..]
    case rest.length
    when 8  # no nono dígito on hand: try it with one inserted
      ["#{prefix}9#{rest}"]
    when 9  # nono dígito present: try it stripped
      ["#{prefix}#{rest[1..]}"]
    else
      []
    end
  end
  private_class_method :br_ninth_digit_alternate
end
