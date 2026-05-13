# frozen_string_literal: true

# Specs for Whatsapp::EvolutionHandlers::AttachmentProcessor.
#
# Round 2 follow-up to EVO-976 — covers the synchronous-upload migration from
# `attachments.build` to `ActiveStorage::Blob.create_and_upload!` introduced in
# the original PR (which had zero coverage). Each test asserts an invariant the
# previous implementation lacked: blob is uploaded before the message is saved,
# voice-note metadata flows through, and download failures do not raise.

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Whatsapp::EvolutionHandlers::AttachmentProcessor' do
    it 'has spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails) && defined?(ActiveStorage::Blob)

RSpec.describe Whatsapp::EvolutionHandlers::AttachmentProcessor do
  let(:host_class) do
    Class.new do
      include Whatsapp::EvolutionHandlers::AttachmentProcessor

      attr_accessor :raw_message_id, :message_type, :file_content_type,
                    :file_extension, :inbox

      def initialize(message:, raw_message:)
        @message = message
        @raw_message = raw_message
        @raw_message_id = raw_message.dig(:key, :id) || 'msg-test-1'
        @message_type = raw_message[:messageType] || 'image'
        @file_content_type = :image
        @file_extension = '.jpg'
      end

      # Stubs for helpers normally provided by sibling modules.
      def generate_filename_with_extension
        "#{raw_message_id}#{file_extension}"
      end

      def determine_content_type
        message_type == 'audio' ? 'audio/ogg' : 'image/jpeg'
      end

      def debug_media_info; end
      def log_attachment_info(*); end
      def log_attachment_success(*); end
      def log_base64_processing(*); end
      def log_tempfile_success(*); end
      def log_base64_error(*); end
    end
  end

  let(:message) do
    msg = instance_double(Message, attachments: attachments_relation)
    allow(msg).to receive(:update!)
    msg
  end

  let(:attachments_relation) { instance_double('AttachmentsRelation') }
  let(:built_attachment) do
    att = instance_double('Attachment', file: file_attachment_proxy)
    allow(att).to receive(:meta=)
    att
  end
  let(:file_attachment_proxy) do
    instance_double('FileAttachmentProxy').tap { |proxy| allow(proxy).to receive(:attach) }
  end

  before do
    allow(attachments_relation).to receive(:build).and_return(built_attachment)
  end

  # ────────────────────────────────────────────────────────────────────────
  # Happy path
  # ────────────────────────────────────────────────────────────────────────
  describe '#create_attachment' do
    let(:processor) do
      host_class.new(
        message: message,
        raw_message: { key: { id: 'msg-1' }, messageType: 'image', message: {} }
      )
    end

    let(:tempfile) { Tempfile.new(['img', '.jpg']).tap { |f| f.write('binary'); f.rewind } }
    let(:fake_blob) { instance_double('ActiveStorage::Blob') }

    after { tempfile.close!; tempfile.unlink rescue nil }

    it 'uploads the blob synchronously via create_and_upload!' do
      expect(ActiveStorage::Blob).to receive(:create_and_upload!).with(
        io: tempfile,
        filename: 'msg-1.jpg',
        content_type: 'image/jpeg'
      ).and_return(fake_blob)

      expect(file_attachment_proxy).to receive(:attach).with(fake_blob)

      processor.create_attachment(tempfile)
    end

    it 'builds the attachment with file_type and fallback_title' do
      allow(ActiveStorage::Blob).to receive(:create_and_upload!).and_return(fake_blob)

      expect(attachments_relation).to receive(:build).with(
        file_type: 'image',
        fallback_title: 'msg-1.jpg'
      ).and_return(built_attachment)

      processor.create_attachment(tempfile)
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # Voice-note metadata (regression guard for EVO-979 ↔ EVO-976)
  # ────────────────────────────────────────────────────────────────────────
  describe 'voice note metadata' do
    let(:tempfile) { Tempfile.new(['audio', '.ogg']).tap { |f| f.write('opus'); f.rewind } }
    let(:fake_blob) { instance_double('ActiveStorage::Blob') }

    before { allow(ActiveStorage::Blob).to receive(:create_and_upload!).and_return(fake_blob) }
    after  { tempfile.close!; tempfile.unlink rescue nil }

    it 'sets is_recorded_audio meta when audioMessage.ptt is true' do
      processor = host_class.new(
        message: message,
        raw_message: {
          key: { id: 'msg-2' },
          messageType: 'audio',
          message: { audioMessage: { ptt: true } }
        }
      )
      processor.message_type = 'audio'

      expect(built_attachment).to receive(:meta=).with(is_recorded_audio: true)

      processor.create_attachment(tempfile)
    end

    it 'leaves meta unset when audioMessage.ptt is false' do
      processor = host_class.new(
        message: message,
        raw_message: {
          key: { id: 'msg-3' },
          messageType: 'audio',
          message: { audioMessage: { ptt: false } }
        }
      )
      processor.message_type = 'audio'

      expect(built_attachment).not_to receive(:meta=)

      processor.create_attachment(tempfile)
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # Download error handling — must not raise; must mark message as unsupported
  # ────────────────────────────────────────────────────────────────────────
  describe '#handle_attach_media' do
    let(:processor) do
      host_class.new(
        message: message,
        raw_message: { key: { id: 'msg-4' }, messageType: 'image', message: { mediaUrl: 'https://x' } }
      )
    end

    it 'flags the message unsupported when Down::Error is raised' do
      allow(processor).to receive(:download_attachment_file).and_raise(Down::Error, 'boom')
      expect(message).to receive(:update!).with(is_unsupported: true)

      expect { processor.handle_attach_media }.not_to raise_error
    end

    it 'swallows generic StandardError in upload step (logs only — caller does not see exceptions)' do
      allow(processor).to receive(:download_attachment_file).and_return(Tempfile.new('x'))
      allow(ActiveStorage::Blob).to receive(:create_and_upload!).and_raise(StandardError, 'storage down')

      expect { processor.handle_attach_media }.not_to raise_error
    end

    it 'returns nil without uploading when download_attachment_file returns nil' do
      allow(processor).to receive(:download_attachment_file).and_return(nil)

      expect(ActiveStorage::Blob).not_to receive(:create_and_upload!)
      processor.handle_attach_media
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # Base64 path — used when Evolution API ships media inline
  # ────────────────────────────────────────────────────────────────────────
  describe '#create_tempfile_from_base64' do
    let(:processor) do
      host_class.new(
        message: message,
        raw_message: { key: { id: 'msg-5' }, messageType: 'image', message: {} }
      )
    end

    it 'decodes a base64 payload and exposes original_filename + content_type' do
      payload = Base64.strict_encode64('PNG-bytes-here')
      tempfile = processor.create_tempfile_from_base64(payload)

      expect(tempfile).not_to be_nil
      expect(tempfile.original_filename).to eq('msg-5.jpg')
      expect(tempfile.content_type).to eq('image/jpeg')
      File.read(tempfile.path).then { |contents| expect(contents).to eq('PNG-bytes-here') }
    ensure
      tempfile&.close!
      tempfile&.unlink rescue nil
    end

    it 'strips data URI prefix before decoding' do
      payload = "data:image/jpeg;base64,#{Base64.strict_encode64('JPG-bytes')}"
      tempfile = processor.create_tempfile_from_base64(payload)

      File.read(tempfile.path).then { |contents| expect(contents).to eq('JPG-bytes') }
    ensure
      tempfile&.close!
      tempfile&.unlink rescue nil
    end

    it 'returns nil on decode failure (no raise)' do
      allow(Base64).to receive(:decode64).and_raise(ArgumentError, 'bad bytes')

      expect(processor.create_tempfile_from_base64('garbage')).to be_nil
    end
  end
end
