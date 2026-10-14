# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::Providers::BaseService do
  let(:whatsapp_channel) { instance_double(Channel::Whatsapp) }
  let(:service) { described_class.new(whatsapp_channel: whatsapp_channel) }

  describe '#html_to_whatsapp' do
    it 'keeps a bare ampersand as-is instead of emitting &amp;' do
      expect(service.html_to_whatsapp('Moët & Chandon Brut Impérial'))
        .to eq('Moët & Chandon Brut Impérial')
    end

    it 'keeps less-than and greater-than signs in plain text' do
      expect(service.html_to_whatsapp('rótulos entre R$ 200 < x > R$ 100'))
        .to eq('rótulos entre R$ 200 < x > R$ 100')
    end

    it 'decodes entities that arrive already escaped from rich-text content' do
      expect(service.html_to_whatsapp('<p>Moët &amp; Chandon</p>'))
        .to eq('Moët & Chandon')
    end

    it 'still converts formatting tags to WhatsApp markup' do
      expect(service.html_to_whatsapp('<strong>Brut</strong> & <em>Rosé</em>'))
        .to eq('*Brut* & _Rosé_')
    end
  end
end
