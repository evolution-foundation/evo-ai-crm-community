class Api::V1::KnowledgeDocumentsController < Api::V1::BaseController
  class FileTooLargeError < StandardError; end

  require_permissions({
    index: 'ai_agents.read',
    show: 'ai_agents.read',
    create: 'ai_agents.create',
    upload: 'ai_agents.create',
    from_url: 'ai_agents.create',
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

  def upload
    unless params[:file].respond_to?(:original_filename)
      return render json: { errors: ['file is required'] }, status: :unprocessable_entity
    end

    extracted = extract_uploaded_text(params[:file])

    @document = @knowledge_base.knowledge_documents.new(
      title: params[:title].presence || params[:file]&.original_filename,
      source_type: 'upload',
      status: 'processing',
      tags: Array(params[:tags]),
      metadata: { 'raw_content' => extracted }
    )
    @document.source_file.attach(params[:file])

    if @document.save
      success_response(data: KnowledgeDocumentSerializer.serialize(@document), status: :created)
    else
      render json: { errors: @document.errors.full_messages }, status: :unprocessable_entity
    end
  rescue Knowledge::TextExtractor::UnsupportedFormatError, FileTooLargeError => e
    render json: { errors: [e.message] }, status: :unprocessable_entity
  end

  def from_url
    @document = @knowledge_base.knowledge_documents.new(
      title: params[:url],
      source_type: 'url',
      source_url: params[:url],
      status: 'crawling',
      tags: Array(params[:tags])
    )

    if @document.save
      Knowledge::UrlIngestJob.perform_later(
        @document,
        include_subpages: ActiveModel::Type::Boolean.new.cast(params[:include_subpages]),
        max_pages: (params[:max_pages] || 1).to_i
      )
      success_response(data: KnowledgeDocumentSerializer.serialize(@document), status: :created)
    else
      render json: { errors: @document.errors.full_messages }, status: :unprocessable_entity
    end
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

  def extract_uploaded_text(file)
    if file.size > KnowledgeDocument::MAX_FILE_SIZE
      raise FileTooLargeError, "File size must be smaller than #{KnowledgeDocument::MAX_FILE_SIZE / 1.megabyte}MB"
    end

    file.tempfile.rewind

    Tempfile.create(['upload', File.extname(file.original_filename)], binmode: true) do |tmp|
      IO.copy_stream(file.tempfile, tmp)
      tmp.flush
      Knowledge::TextExtractor.new(tmp.path, file.content_type).extract
    end
  end
end
