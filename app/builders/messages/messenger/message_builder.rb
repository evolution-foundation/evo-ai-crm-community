class Messages::Messenger::MessageBuilder
  include ::FileTypeHelper

  def process_attachment(attachment)
    # This check handles very rare case if there are multiple files to attach with only one usupported file
    return if unsupported_file_type?(attachment['type'])

    params = attachment_params(attachment)
    attachment_obj = @message.attachments.new(params.except(:remote_file_url, :preview_file_url))
    attachment_obj.save!
    attach_file(attachment_obj, params[:remote_file_url]) if params[:remote_file_url]
    attach_preview_file(attachment_obj, params[:preview_file_url]) if params[:preview_file_url]
    fetch_story_link(attachment_obj) if attachment_obj.file_type == 'story_mention'
    update_attachment_file_type(attachment_obj)
  end

  def attach_file(attachment, file_url)
    attachment_file = Down.download(
      file_url
    )
    attachment.file.attach(
      io: attachment_file,
      filename: attachment_file.original_filename,
      content_type: attachment_file.content_type
    )
  end

  def attach_preview_file(attachment, file_url)
    attach_file(attachment, file_url)
  rescue StandardError => e
    Rails.logger.info("Instagram Reel preview image unavailable: #{e.class}")
  end

  def attachment_params(attachment)
    file_type = attachment['type'].to_sym
    params = { file_type: file_type }

    if [:image, :file, :audio, :video, :share, :story_mention, :ig_reel].include? file_type
      params.merge!(file_type_params(attachment))
    elsif file_type == :location
      params.merge!(location_params(attachment))
    elsif file_type == :fallback
      params.merge!(fallback_params(attachment))
    end

    params
  end

  def file_type_params(attachment)
    if attachment['type'].to_s == 'ig_reel'
      metadata = Instagram::ReelPreview.new(attachment.dig('payload', 'url')).call
      canonical_url = metadata[:canonical_url] || attachment.dig('payload', 'url')

      return {
        external_url: canonical_url,
        fallback_title: metadata[:title].presence || 'Instagram Reel',
        meta: metadata,
        preview_file_url: metadata[:preview_image_url]
      }
    end

    {
      external_url: attachment['payload']['url'],
      remote_file_url: attachment['payload']['url']
    }
  end

  def update_attachment_file_type(attachment)
    return if @message.reload.attachments.blank?
    return unless attachment.file_type == 'share' || attachment.file_type == 'story_mention'

    attachment.file_type = file_type(attachment.file&.content_type)
    attachment.save!
  end

  def fetch_story_link(attachment)
    message = attachment.message
    result = get_story_object_from_source_id(message.source_id)

    return if result.blank?

    story_id = result['story']['mention']['id']
    story_sender = result['from']['username']
    message.content_attributes[:story_sender] = story_sender
    message.content_attributes[:story_id] = story_id
    message.content_attributes[:image_type] = 'story_mention'
    message.content = I18n.t('conversations.messages.instagram_story_content', story_sender: story_sender)
    message.save!
  end

  def get_story_object_from_source_id(_source_id)
    {}
  end

  private

  def unsupported_file_type?(attachment_type)
    [:template, :unsupported_type].include? attachment_type.to_sym
  end
end
