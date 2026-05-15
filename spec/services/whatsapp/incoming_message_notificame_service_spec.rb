# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Whatsapp::IncomingMessageNotificameService' do
    it 'has service spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Whatsapp::IncomingMessageNotificameService do
  describe '#attach_file fallback_title resolution' do
    let(:provider_service) { instance_double('Whatsapp::Providers::NotificameService') }
    let(:channel) { instance_double(Channel::Whatsapp, provider_service: provider_service) }
    let(:inbox) { instance_double(Inbox, channel: channel) }
    let(:service) { described_class.new(inbox: inbox, params: {}) }

    let(:attachments_collection) { instance_double('ActiveRecord::Associations::CollectionProxy') }
    let(:message) { instance_double(Message, attachments: attachments_collection) }

    let(:download_response) do
      instance_double('HTTParty::Response', success?: true, body: "\x25PDF-1.4\x00".b, code: 200)
    end

    before do
      allow(provider_service).to receive(:download_media).and_return(download_response)
      allow(service).to receive(:file_content_type).and_return(:file)
    end

    it 'uses content[:fileName] when present in the payload' do
      content = {
        fileMimeType: 'application/pdf',
        fileUrl: 'https://cdn.notificame/abc123def',
        fileName: 'relatorio-q2.pdf'
      }

      expect(attachments_collection).to receive(:new) do |args|
        expect(args[:fallback_title]).to eq('relatorio-q2.pdf')
        expect(args[:file]).to include(content_type: 'application/pdf')
        expect(args[:file][:io]).to respond_to(:read)
        expect(args[:file][:filename]).to be_a(String).and(be_present)
      end

      service.send(:attach_file, message, content)
    end

    it 'falls back to URL basename when content[:fileName] is missing' do
      content = {
        fileMimeType: 'application/pdf',
        fileUrl: 'https://cdn.notificame/files/manual.pdf'
      }

      expect(attachments_collection).to receive(:new) do |args|
        expect(args[:fallback_title]).to eq('manual.pdf')
      end

      service.send(:attach_file, message, content)
    end

    it 'falls back to URL basename when content[:fileName] is blank' do
      content = {
        fileMimeType: 'application/pdf',
        fileUrl: 'https://cdn.notificame/files/manual.pdf',
        fileName: ''
      }

      expect(attachments_collection).to receive(:new) do |args|
        expect(args[:fallback_title]).to eq('manual.pdf')
      end

      service.send(:attach_file, message, content)
    end
  end
end
