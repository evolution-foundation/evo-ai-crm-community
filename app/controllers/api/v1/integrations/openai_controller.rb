class Api::V1::Integrations::OpenaiController < Api::V1::BaseController
  def process_event
    # Use global configuration instead of hook settings
    processor = Integrations::Openai::GlobalProcessorService.new(
      account: nil,
      event: permitted_event_params
    )

    result = processor.perform

    if result.present?
      render json: result
    else
      render json: { error: 'Unable to process request' }, status: :unprocessable_entity
    end
  rescue StandardError => e
    Rails.logger.error "OpenAI Global Processing Error: #{e.message}"
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def permitted_event_params
    params.require(:event).permit(:name, data: {})
  end
end
