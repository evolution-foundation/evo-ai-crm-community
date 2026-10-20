# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Messages::Messenger::MessageBuilder do
  subject(:builder) { described_class.allocate }

  describe '#file_type_params' do
    it 'keeps Instagram Reels external and does not download them as files' do
      metadata = {
        canonical_url: 'https://www.instagram.com/reel/ABC123/',
        preview_image_url: 'https://cdninstagram.example/reel.jpg',
        title: 'Vetorial Reel'
      }
      allow(Instagram::ReelPreview).to receive(:new).and_return(instance_double(Instagram::ReelPreview, call: metadata))

      params = builder.file_type_params(
        'type' => 'ig_reel',
        'payload' => { 'url' => 'https://www.instagram.com/reels/ABC123/?igsh=tracking' }
      )

      expect(params).to eq(
        external_url: 'https://www.instagram.com/reel/ABC123/',
        fallback_title: 'Vetorial Reel',
        meta: metadata,
        preview_file_url: 'https://cdninstagram.example/reel.jpg'
      )
      expect(params).not_to have_key(:remote_file_url)
    end
  end
end
