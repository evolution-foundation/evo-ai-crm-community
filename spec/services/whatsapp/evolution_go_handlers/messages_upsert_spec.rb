# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Whatsapp::EvolutionGoHandlers::MessagesUpsert' do
    it 'has spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Whatsapp::EvolutionGoHandlers::MessagesUpsert do
  let(:host_class) do
    Class.new do
      include Whatsapp::EvolutionGoHandlers::MessagesUpsert

      attr_writer :evolution_go_info, :evolution_go_message

      def initialize(info: nil, message: nil)
        @evolution_go_info = info
        @evolution_go_message = message
      end
    end
  end

  subject(:service) { host_class.new(info: info, message: evo_message) }

  let(:evo_message) { {} }
  let(:info) { nil }

  describe '#message_type_from_media' do
    context 'when @evolution_go_info is nil' do
      let(:info) { nil }

      context 'and message struct is videoMessage' do
        let(:evo_message) { { videoMessage: {} } }

        it 'returns video' do
          expect(service.send(:message_type_from_media)).to eq('video')
        end
      end

      context 'and message struct is imageMessage' do
        let(:evo_message) { { imageMessage: {} } }

        it 'returns image' do
          expect(service.send(:message_type_from_media)).to eq('image')
        end
      end

      context 'and message struct is documentMessage' do
        let(:evo_message) { { documentMessage: {} } }

        it 'returns file' do
          expect(service.send(:message_type_from_media)).to eq('file')
        end
      end

      context 'and message struct is audioMessage' do
        let(:evo_message) { { audioMessage: {} } }

        it 'returns audio' do
          expect(service.send(:message_type_from_media)).to eq('audio')
        end
      end

      context 'and message struct is stickerMessage' do
        let(:evo_message) { { stickerMessage: {} } }

        it 'returns sticker' do
          expect(service.send(:message_type_from_media)).to eq('sticker')
        end
      end
    end

    context 'when MediaType is blank string' do
      let(:info) { { MediaType: '' } }
      let(:evo_message) { { videoMessage: {} } }

      it 'falls back to struct-based detection and returns video' do
        expect(service.send(:message_type_from_media)).to eq('video')
      end
    end

    context 'when MediaType is present' do
      let(:evo_message) { {} }

      it 'returns image for MediaType=image' do
        service.instance_variable_set(:@evolution_go_info, { MediaType: 'image' })
        expect(service.send(:message_type_from_media)).to eq('image')
      end

      it 'returns video for MediaType=video' do
        service.instance_variable_set(:@evolution_go_info, { MediaType: 'video' })
        expect(service.send(:message_type_from_media)).to eq('video')
      end

      it 'returns audio for MediaType=audio' do
        service.instance_variable_set(:@evolution_go_info, { MediaType: 'audio' })
        expect(service.send(:message_type_from_media)).to eq('audio')
      end

      it 'returns audio for MediaType=ptt' do
        service.instance_variable_set(:@evolution_go_info, { MediaType: 'ptt' })
        expect(service.send(:message_type_from_media)).to eq('audio')
      end

      it 'returns file for MediaType=document' do
        service.instance_variable_set(:@evolution_go_info, { MediaType: 'document' })
        expect(service.send(:message_type_from_media)).to eq('file')
      end

      it 'returns sticker for MediaType=sticker' do
        service.instance_variable_set(:@evolution_go_info, { MediaType: 'sticker' })
        expect(service.send(:message_type_from_media)).to eq('sticker')
      end

      it 'returns file for unknown MediaType' do
        service.instance_variable_set(:@evolution_go_info, { MediaType: 'unknown_type' })
        expect(service.send(:message_type_from_media)).to eq('file')
      end
    end
  end

  describe '#audio_voice_note?' do
    it 'returns false without raising when @evolution_go_info is nil' do
      service.instance_variable_set(:@evolution_go_info, nil)
      expect { service.send(:audio_voice_note?) }.not_to raise_error
      expect(service.send(:audio_voice_note?)).to be(false)
    end

    it 'returns true when MediaType is ptt' do
      service.instance_variable_set(:@evolution_go_info, { MediaType: 'ptt' })
      expect(service.send(:audio_voice_note?)).to be(true)
    end

    it 'returns false when MediaType is audio' do
      service.instance_variable_set(:@evolution_go_info, { MediaType: 'audio' })
      expect(service.send(:audio_voice_note?)).to be(false)
    end
  end
end
