class Public::Api::V1::CsatSurveyController < PublicController
  before_action :set_conversation
  before_action :set_message

  def show
    render json: survey_payload
  end

  def update
    render json: { error: 'You cannot update the CSAT survey after 14 days' }, status: :unprocessable_entity and return if check_csat_locked

    @message.update!(message_update_params[:message])
    render json: survey_payload
  end

  private

  def set_conversation
    return if params[:id].blank?

    @conversation = Conversation.find_by!(uuid: params[:id])
  end

  def set_message
    @message = @conversation.messages.find_by!(content_type: 'input_csat')
  end

  # Flat, no `{ success:, data: }` envelope: the public survey page reads these
  # keys straight off the response body.
  def survey_payload
    {
      inbox_name: inbox&.name,
      inbox_avatar_url: inbox&.avatar_url,
      display_type: @message.content_attributes&.dig('display_type') || 'emoji',
      content: survey_prompt,
      csat_survey_response: csat_survey_response_payload
    }
  end

  def inbox
    @inbox ||= @conversation.inbox
  end

  # Re-derived from the same source the survey message was built from
  # (MessageTemplates::Template::CsatSurvey#message_content), NOT from the message.
  # `Message#content` appends the survey link for delivery through the channel, and
  # Liquidable's before_create renders that appended string INTO the column — so the
  # stored value carries the link too, and the reader is already on the page it
  # points at.
  def survey_prompt
    configured = inbox&.csat_config&.dig('message')
    return configured if configured.present?

    I18n.t('conversations.templates.csat_input_message_body')
  end

  # nil when nothing was rated yet, never an empty object: the page reads a
  # present `rating` key as "already answered" and would hide the rating widget.
  def csat_survey_response_payload
    response = @message.csat_survey_response
    return nil if response.nil?

    { rating: response.rating, feedback_message: response.feedback_message }
  end

  def message_update_params
    params.permit(message: [{ submitted_values: [:name, :title, :value, { csat_survey_response: [:feedback_message, :rating] }] }])
  end

  def check_csat_locked
    (Time.zone.now.to_date - @message.created_at.to_date).to_i > 14
  end
end
