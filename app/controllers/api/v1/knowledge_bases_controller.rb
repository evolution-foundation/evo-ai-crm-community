class Api::V1::KnowledgeBasesController < Api::V1::BaseController
  require_permissions({
    index: 'ai_agents.read',
    create: 'ai_agents.create',
    destroy: 'ai_agents.delete'
  })

  before_action :knowledge_base, only: [:destroy]

  def index
    @knowledge_bases = KnowledgeBase.order(created_at: :desc)
    success_response(data: KnowledgeBaseSerializer.serialize_collection(@knowledge_bases))
  end

  def create
    @knowledge_base = KnowledgeBase.new(knowledge_base_params)
    if @knowledge_base.save
      success_response(data: KnowledgeBaseSerializer.serialize(@knowledge_base), status: :created)
    else
      render json: { errors: @knowledge_base.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    @knowledge_base.destroy
    head :no_content
  end

  private

  def knowledge_base
    @knowledge_base = KnowledgeBase.find(params[:id])
  end

  def knowledge_base_params
    params.require(:knowledge_base).permit(:name, :active, :default, :embedding_model)
  end
end
