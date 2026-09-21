# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::PhoneNumberNormalizer do
  describe '.call' do
    subject(:normalized) { described_class.call(input) }

    context 'with blank input' do
      [nil, '', '   '].each do |blank|
        context "when input is #{blank.inspect}" do
          let(:input) { blank }

          it { is_expected.to be_nil }
        end
      end
    end

    context 'with Brazilian numbers (+55)' do
      context 'when DDD >= 31 (mobile with extra 9)' do
        # DDD 74, subscriber leads with 9 -> the nono dígito is stripped.
        let(:input) { '5574999879409' }

        it 'strips the 9 to 12 digits' do
          expect(normalized).to eq('557499879409')
        end
      end

      context 'when DDD >= 31 already without the 9' do
        let(:input) { '557499879409' }

        it 'is left unchanged (idempotent)' do
          expect(normalized).to eq('557499879409')
        end
      end

      context 'when DDD < 31 (metro area keeps the 9)' do
        # DDD 11 = São Paulo, the 9 is preserved.
        let(:input) { '5511999879409' }

        it 'keeps the 9 (13 digits)' do
          expect(normalized).to eq('5511999879409')
        end
      end

      context 'when the 8-digit subscriber leads with a digit < 7 (landline-like)' do
        # In createJid, joker = first digit of the captured 8-digit subscriber.
        # 55 74 9 69987940 -> subscriber "69987940", joker 6 (< 7) -> keep intact,
        # even though DDD 74 >= 31.
        let(:input) { '5574969987940' }

        it 'keeps all digits' do
          expect(normalized).to eq('5574969987940')
        end
      end

      context 'with cosmetic formatting (+, spaces, parens)' do
        let(:input) { '+55 (74) 99987-9409' }

        it 'cleans and strips the 9' do
          expect(normalized).to eq('557499879409')
        end
      end
    end

    context 'with Mexican numbers (+52)' do
      context 'when 13 digits with the extra leading 1' do
        let(:input) { '5215512345678' }

        it 'drops the extra digit to 12' do
          expect(normalized).to eq('525512345678')
        end
      end

      context 'when already 12 digits' do
        let(:input) { '525512345678' }

        it 'is left unchanged' do
          expect(normalized).to eq('525512345678')
        end
      end
    end

    context 'with Argentine numbers (+54)' do
      context 'when 13 digits with the extra leading 9' do
        let(:input) { '5491123456789' }

        it 'drops the extra digit to 12' do
          expect(normalized).to eq('541123456789')
        end
      end
    end

    context 'with other countries' do
      # US +1 number — no special casing, only cosmetic cleanup.
      let(:input) { '+1 (415) 555-2671' }

      it 'returns digits unchanged' do
        expect(normalized).to eq('14155552671')
      end
    end

    context 'idempotency' do
      it 'normalizing twice yields the same result' do
        once = described_class.call('5574999879409')
        twice = described_class.call(once)
        expect(twice).to eq(once)
      end
    end
  end

  describe '.e164_variants' do
    it 'lists both Brazilian forms for a DDD >= 31 mobile, whichever one comes in' do
      expected = %w[+5531988887777 +553188887777]

      expect(described_class.e164_variants('+5531988887777')).to match_array(expected)
      expect(described_class.e164_variants('553188887777@s.whatsapp.net')).to match_array(expected)
    end

    it 'lists a single form where the channel applies no quirk' do
      expect(described_class.e164_variants('+5511988887777')).to eq(%w[+5511988887777])
      expect(described_class.e164_variants('+553132221111')).to eq(%w[+553132221111])
      expect(described_class.e164_variants('+351912345678')).to eq(%w[+351912345678])
    end

    it 'lists both forms for Mexico and Argentina' do
      expect(described_class.e164_variants('+5215512345678')).to match_array(%w[+5215512345678 +525512345678])
      expect(described_class.e164_variants('+541112345678')).to match_array(%w[+541112345678 +5491112345678])
    end

    it 'puts the informed number first' do
      expect(described_class.e164_variants('+553188887777').first).to eq('+553188887777')
      expect(described_class.e164_variants('+5531988887777').first).to eq('+5531988887777')
    end

    it 'is empty for blank input' do
      expect(described_class.e164_variants(nil)).to eq([])
      expect(described_class.e164_variants('  ')).to eq([])
    end

    it 'only lists numbers that normalize to the same canonical form' do
      %w[+5531988887777 +5215512345678 +5491112345678 +5511988887777].each do |number|
        forms = described_class.e164_variants(number)
        expect(forms.map { |form| described_class.call(form) }.uniq.size).to eq(1)
      end
    end
  end
end
