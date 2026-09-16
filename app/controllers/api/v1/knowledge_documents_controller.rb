class Api::V1::KnowledgeDocumentsController < Api::V1::BaseController
  require_permissions({
    index: 'ai_agents.read',
    show: 'ai_agents.read',
    create: 'ai_agents.create',
    destroy: 'ai_agents.delete'
  })

  before_action :knowledge_base
  before_action :document, only: [:show, :destroy]

  def index
    @documents = @knowledge_base.knowledge_documents.ordered
    apply_pagination
    paginated_response(data: KnowledgeDocumentSerializer.serialize_collection(@documents), collection: @documents)
  end

  def show
    success_response(data: KnowledgeDocumentSerializer.serialize(@document))
  end

  def create
    attributes = document_params.except(:content).merge(source_type: 'manual', status: 'processing')
    @document = @knowledge_base.knowledge_documents.new(attributes)
    @document.metadata = { 'raw_content' => document_params[:content] }

    if @document.save
      success_response(data: KnowledgeDocumentSerializer.serialize(@document), status: :created)
    else
      render json: { errors: @document.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    @document.destroy
    head :no_content
  end

  private

  def knowledge_base
    @knowledge_base = KnowledgeBase.find(params[:knowledge_base_id])
  end

  def document
    @document = @knowledge_base.knowledge_documents.find(params[:id])
  end

  def document_params
    params.require(:knowledge_document).permit(:title, :description, :content, tags: [])
  end
end
