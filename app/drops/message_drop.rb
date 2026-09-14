class MessageDrop < BaseDrop
  include MessageFormatHelper

  def sender_display_name
    @obj.sender.try(:available_name)
  end

  def text_content
    content = @obj.try(:content) || ''
    render_message_content(message_body_content(content))
  end
end
