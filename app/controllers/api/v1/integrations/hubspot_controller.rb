class Api::V1::Integrations::HubspotController < Api::V1::BaseController
  before_action :fetch_conversation, only: [:link_deal, :linked_deals]
  before_action :fetch_hook, only: [:destroy]

  def destroy
    @hook.destroy!
    head :ok
  end

  def pipelines
    pipelines = hubspot_processor_service.pipelines
    if pipelines[:error]
      render json: { error: pipelines[:error] }, status: :unprocessable_entity
    else
      render json: pipelines[:data], status: :ok
    end
  end

  def pipeline_stages
    pipeline_id = permitted_params[:pipeline_id]
    stages = hubspot_processor_service.pipeline_stages(pipeline_id)
    if stages[:error]
      render json: { error: stages[:error] }, status: :unprocessable_entity
    else
      render json: stages[:data], status: :ok
    end
  end

  def owners
    owners = hubspot_processor_service.owners
    if owners[:error]
      render json: { error: owners[:error] }, status: :unprocessable_entity
    else
      render json: owners[:data], status: :ok
    end
  end

  def create_deal
    deal = hubspot_processor_service.create_deal(permitted_params)
    if deal[:error]
      render json: { error: deal[:error] }, status: :unprocessable_entity
    else
      render json: deal[:data], status: :ok
    end
  end

  def link_deal
    deal_id = permitted_params[:deal_id]
    title = permitted_params[:title]
    deal = hubspot_processor_service.link_deal(conversation_link, deal_id, title)
    if deal[:error]
      render json: { error: deal[:error] }, status: :unprocessable_entity
    else
      render json: deal[:data], status: :ok
    end
  end

  def unlink_deal
    link_id = permitted_params[:link_id]
    deal = hubspot_processor_service.unlink_deal(link_id)

    if deal[:error]
      render json: { error: deal[:error] }, status: :unprocessable_entity
    else
      render json: deal[:data], status: :ok
    end
  end

  def linked_deals
    deals = hubspot_processor_service.linked_deals(conversation_link)

    if deals[:error]
      render json: { error: deals[:error] }, status: :unprocessable_entity
    else
      render json: deals[:data], status: :ok
    end
  end

  def search_deals
    term = params[:q] || '' # Allow empty search to get recent deals
    deals = hubspot_processor_service.search_deals(term)
    if deals[:error]
      render json: { error: deals[:error] }, status: :unprocessable_entity
    else
      render json: deals[:data], status: :ok
    end
  end

  private

  def conversation_link
    "#{ENV.fetch('FRONTEND_URL', nil)}/app/conversations/#{@conversation.display_id}"
  end

  def fetch_conversation
    @conversation = Conversation.find_by!(display_id: permitted_params[:conversation_id])
  end

  def hubspot_processor_service
    Integrations::Hubspot::ProcessorService.new(account: nil)
  end

  def permitted_params
    params.permit(:pipeline_id, :conversation_id, :deal_id, :link_id, :title, :description, :owner_id, :stage_id, :amount, :close_date)
  end

  def fetch_hook
    @hook = Integrations::Hook.find_by(app_id: 'hubspot')
  end
end
