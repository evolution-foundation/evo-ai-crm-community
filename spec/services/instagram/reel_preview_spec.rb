# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Instagram::ReelPreview do
  subject(:preview) { described_class.new(raw_url) }

  let(:raw_url) { 'https://www.instagram.com/reels/ABC123/?igsh=tracking' }

  describe '#call' do
    it 'normalizes the Reel URL and extracts Open Graph metadata' do
      response = Net::HTTPOK.new('1.1', '200', 'OK')
      response['content-type'] = 'text/html; charset=utf-8'
      response.instance_variable_set(:@body, <<~HTML)
        <html><head>
          <meta property="og:title" content="Vetorial Reel">
          <meta property="og:description" content="Editorial campaign">
          <meta property="og:image" content="https://cdninstagram.example/reel.jpg">
        </head></html>
      HTML
      allow(preview).to receive(:request).and_return(response)

      expect(preview.call).to include(
        canonical_url: 'https://www.instagram.com/reel/ABC123/',
        shortcode: 'ABC123',
        title: 'Vetorial Reel',
        description: 'Editorial campaign',
        preview_image_url: 'https://cdninstagram.example/reel.jpg'
      )
    end

    it 'decodes HTML entities in Open Graph image URLs' do
      response = Net::HTTPOK.new('1.1', '200', 'OK')
      response['content-type'] = 'text/html; charset=utf-8'
      response.instance_variable_set(
        :@body,
        '<meta property="og:image" content="https://cdninstagram.example/reel.jpg?a=1&amp;amp;b=2">'
      )
      allow(preview).to receive(:request).and_return(response)

      expect(preview.call[:preview_image_url]).to eq('https://cdninstagram.example/reel.jpg?a=1&b=2')
    end

    it 'does not fetch or normalize non-Instagram URLs' do
      service = described_class.new('https://example.com/reel/ABC123')
      allow(service).to receive(:request)

      expect(service.call).to eq(original_url: 'https://example.com/reel/ABC123')
      expect(service).not_to have_received(:request)
    end
  end
end
