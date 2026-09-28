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

  describe '.to_e164_candidates' do
    subject(:candidates) { described_class.to_e164_candidates(input) }

    context 'with blank input' do
      let(:input) { '' }

      it { is_expected.to eq([]) }
    end

    context 'when the BR number is missing its nono dígito (12 digits)' do
      let(:input) { '551187654321' }

      it 'includes both the as-is form and the form with the 9 inserted' do
        expect(candidates).to contain_exactly('+551187654321', '+5511987654321')
      end
    end

    context 'when the BR number already carries the nono dígito (13 digits)' do
      let(:input) { '5511987654321' }

      it 'includes both the as-is form and the form with the 9 stripped' do
        expect(candidates).to contain_exactly('+5511987654321', '+551187654321')
      end
    end

    context 'with a non-BR number' do
      let(:input) { '+1 (415) 555-2671' }

      it 'returns only the single canonical form' do
        expect(candidates).to eq(['+14155552671'])
      end
    end
  end
end
