class Api::V1::Widget::MessagesController < Api::V1::Widget::BaseController
  before_action :reject_if_inbox_archived, only: [:create]
  before_action :set_conversation, only: [:create]
  before_action :set_message, only: [:update]

  def index
    @messages = conversation.nil? ? [] : message_finder.perform
  end

  def create
    # Se veio conversation_id explícito e não encontrou, retornar 404
    conversation_id = permitted_params.dig(:message, :conversation_id)
    if conversation_id.present? && conversation.nil?
      render json: { error: 'Conversation not found', code: 'CONVERSATION_NOT_FOUND' },
             status: :not_found and return
    end

    # Validar se pode enviar mensagem nesta conversa
    validate_conversation_status!

    @message = conversation.messages.new(message_params)
    build_attachment
    @message.save!
  end

  def update
    if @message.content_type == 'input_email'
      @message.update!(submitted_email: contact_email)
      ContactIdentifyAction.new(
        contact: @contact,
        params: { email: contact_email, name: contact_name },
        retain_original_contact_name: true
      ).perform
    else
      @message.update!(message_update_params[:message])
    end
  rescue StandardError => e
    render json: { error: @contact.errors, message: e.message }.to_json, status: :internal_server_error
  end

  private

  def build_attachment
    return if params[:message][:attachments].blank?

    params[:message][:attachments].each do |uploaded_attachment|
      attachment = @message.attachments.new(
        file: uploaded_attachment
      )

      attachment.file_type = helpers.file_type(uploaded_attachment&.content_type) if uploaded_attachment.is_a?(ActionDispatch::Http::UploadedFile)
    end
  end

  def set_conversation
    # Se conversation_id foi fornecido, não criar nova conversa automaticamente
    conversation_id = permitted_params.dig(:message, :conversation_id)
    return if conversation_id.present?

    # Criar nova conversa se não veio conversation_id e não existe conversa
    @conversation = create_conversation if conversation.nil?
  end


  def message_finder_params
    {
      filter_internal_messages: true,
      before: permitted_params[:before],
      after: permitted_params[:after]
    }
  end

  def message_finder
    @message_finder ||= MessageFinder.new(conversation, message_finder_params)
  end

  def message_update_params
    params.permit(message: [{ submitted_values: [:name, :title, :value, { csat_survey_response: [:feedback_message, :rating] }] }])
  end

  def permitted_params
    # timestamp parameter is used in create conversation method
    params.permit(:id, :before, :after, :website_token, contact: [:name, :email],
                  message: [:content, :referer_url, :timestamp, :echo_id, :reply_to, :conversation_id, attachments: []])
  end

  def set_message
    @message = @web_widget.inbox.messages.find(permitted_params[:id])
  end

  def validate_conversation_status!
    return unless conversation&.resolved?

    # Se a conversa está resolvida, verificar se o inbox permite mensagens após resolução
    unless inbox.allow_messages_after_resolved
      render json: {
        error: 'Cannot send messages to a resolved conversation',
        code: 'CONVERSATION_RESOLVED'
      }, status: :forbidden and return
    end
  end
end
