class Api::V1::LabelsController < Api::V1::BaseController
  # Configuração de permissões - Apenas actions que realmente precisam de verificação
  require_permissions({
    create: 'labels.create',
    update: 'labels.update', 
    destroy: 'labels.delete'
  })
  # index e show são permitidos para todos (sem verificação de permissão)

  before_action :fetch_label, except: [:index, :create]

  def index
    @labels = Label.all
    
    apply_pagination
    
    paginated_response(
      data: LabelSerializer.serialize_collection(@labels),
      collection: @labels,
      message: 'Labels retrieved successfully'
    )
  end

  def show
    success_response(
      data: LabelSerializer.serialize(@label),
      message: 'Label retrieved successfully'
    )
  end

  def create
    @label = Label.all.new(permitted_params)
    
    if @label.save
      success_response(
        data: LabelSerializer.serialize(@label),
        message: 'Label created successfully',
        status: :created
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Validation failed',
        details: format_validation_errors(@label.errors),
        status: :unprocessable_entity
      )
    end
  end

  def update
    if @label.update(permitted_params)
      success_response(
        data: LabelSerializer.serialize(@label),
        message: 'Label updated successfully'
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Validation failed',
        details: format_validation_errors(@label.errors),
        status: :unprocessable_entity
      )
    end
  end

  def destroy
    @label.destroy
    success_response(
      data: { id: @label.id },
      message: 'Label deleted successfully'
    )
  end

  private

  def fetch_label
    @label = Label.all.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    error_response(
      code: ApiErrorCodes::LABEL_NOT_FOUND,
      message: "Label with id #{params[:id]} not found",
      status: :not_found
    )
  end

  def permitted_params
    params.require(:label).permit(:title, :description, :color, :show_on_sidebar)
  end
end
