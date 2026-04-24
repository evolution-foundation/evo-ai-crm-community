require 'base64'
require 'tempfile'

module Whatsapp::EvolutionHandlers::AttachmentProcessor
  include Whatsapp::EvolutionHandlers::AttachmentLogger

  def handle_attach_media
    Rails.logger.info "Evolution API: Processing attachment for message #{raw_message_id}, type: #{message_type}"

    debug_media_info
    attachment_file = download_attachment_file
    return unless attachment_file

    create_attachment(attachment_file)
  rescue Down::Error => e
    @message.update!(is_unsupported: true)
    Rails.logger.error "Evolution API: Failed to download attachment for message #{raw_message_id}: #{e.message}"
  rescue StandardError => e
    Rails.logger.error "Evolution API: Failed to create attachment for message #{raw_message_id}: #{e.message}"
    Rails.logger.error "  - Error class: #{e.class}"
    Rails.logger.error "  - Error details: #{e.inspect}"
  end

  def create_attachment(attachment_file)
    final_filename = generate_filename_with_extension
    final_content_type = determine_content_type

    log_attachment_info(attachment_file, final_filename, final_content_type)

    blob = ActiveStorage::Blob.create_and_upload!(
      io: attachment_file,
      filename: final_filename,
      content_type: final_content_type
    )

    attachment = @message.attachments.build(file_type: file_content_type.to_s)
    attachment.file.attach(blob)

    configure_audio_metadata(attachment) if audio_voice_note?
    log_attachment_success(attachment)
  end

  def download_attachment_file
    message = @raw_message[:message]

    if message[:base64].present?
      Rails.logger.info 'Evolution API: Processing base64 attachment'
      return create_tempfile_from_base64(message[:base64])
    end

    if message[:mediaUrl].present?
      Rails.logger.info "Evolution API: Downloading from mediaUrl: #{message[:mediaUrl]}"
      return Down.download(message[:mediaUrl], headers: inbox.channel.api_headers)
    end

    Rails.logger.warn 'Evolution API: No media found - no base64 or mediaUrl'
    nil
  rescue StandardError => e
    Rails.logger.error "Evolution API: Failed to download media: #{e.message}"
    nil
  end

  def create_tempfile_from_base64(base64_data)
    base64_clean = base64_data.gsub(/^data:.*?;base64,/, '')
    decoded_data = Base64.decode64(base64_clean)

    content_type = determine_content_type
    file_name = generate_filename_with_extension

    log_base64_processing(decoded_data, content_type, file_name)

    tempfile = create_and_configure_tempfile(decoded_data, file_name, content_type)
    log_tempfile_success(tempfile)

    tempfile
  rescue StandardError => e
    log_base64_error(e, base64_data)
    nil
  end

  private

  def configure_audio_metadata(attachment)
    attachment.meta = { is_recorded_audio: true } if message_type == 'audio' && @raw_message.dig(:message, :audioMessage, :ptt)
  end

  def audio_voice_note?
    message_type == 'audio' && @raw_message.dig(:message, :audioMessage, :ptt)
  end

  def create_and_configure_tempfile(decoded_data, file_name, content_type)
    tempfile = Tempfile.new([raw_message_id, file_extension])
    tempfile.binmode
    tempfile.write(decoded_data)
    tempfile.rewind

    add_tempfile_methods(tempfile, file_name, content_type)
    tempfile
  end

  def add_tempfile_methods(tempfile, file_name, content_type)
    tempfile.define_singleton_method(:original_filename) { file_name }
    tempfile.define_singleton_method(:content_type) { content_type }
    tempfile.define_singleton_method(:size) { File.size(path) }
  end
end
